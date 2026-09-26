# frozen_string_literal: true

require "delegate"
require "tmpdir"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/store"

# README 3c against the harness's sample schema (spec/support/postgres),
# public.customers and public.orders, with more indexes and an extended
# statistics object added and then ANALYZE run:
#
# - orders_pending_idx is partial, and customers_lower_email_idx is on an
#   expression, so Postgres keeps statistics for its lower(email) column.
# - customers_email_ff_idx has a WITH option, which IndexCandidate can't
#   represent.
# - orders_customer_id_key is a UNIQUE index built CONCURRENTLY. Many orders
#   share a customer, so the build fails and leaves the index invalid.
# - orders_status_customer is CREATE STATISTICS (ndistinct, dependencies,
#   mcv) on status and customer_id.
#
# The tables are small enough that ANALYZE reads every row, so the numbers
# below are the data's own (see data.sql).
RSpec.describe Quaack::Enclave::PlannerStatistics do
  let(:db) { test_database }
  let(:conn) { db.connection }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }
  let(:orders) { table("public", "orders") }
  let(:customers) { table("public", "customers") }

  around do |example|
    Dir.mktmpdir("quaack-planner-statistics") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  before do
    conn.exec(<<~SQL)
      CREATE INDEX orders_pending_idx ON orders (created_at) WHERE status = 'pending';
      CREATE INDEX customers_lower_email_idx ON customers (lower(email));
      CREATE INDEX customers_email_ff_idx ON customers (email) WITH (fillfactor = 70);
      CREATE STATISTICS orders_status_customer (ndistinct, dependencies, mcv) ON status, customer_id FROM orders;
    SQL
    expect { conn.exec("CREATE UNIQUE INDEX CONCURRENTLY orders_customer_id_key ON orders (customer_id)") }
      .to raise_error(PG::UniqueViolation)
    conn.exec("ANALYZE customers, orders")
  end

  def table(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  def run(relations = [customers, orders], connection: conn) = described_class.run(store:, relations:, connection:)

  def stored_table(name) = store.read("statistics")["tables"].find { it["name"] == name }

  def error_of
    yield
    raise "expected an error"
  rescue Quaack::Enclave::PlannerStatistics::Error, Quaack::Enclave::Inventory::Error => e
    e
  end

  describe "the stored pg_stats" do
    it "has each column's pg_stats row, with the MCV list, histogram, and scalars" do
      run
      status = stored_table("orders")["columns"]["status"]

      expect(status["most_common_vals"]).to eq(%w[delivered shipped pending cancelled returned failed])
      expect(status["most_common_freqs"].zip([0.71, 0.12, 0.09, 0.04, 0.03, 0.01])).to all(
        satisfy { |ours, want| (ours - want).abs < 0.001 }
      )
      expect(status).to include("n_distinct" => 6.0, "null_frac" => 0.0, "histogram_bounds" => nil)
      expect(status["correlation"]).to be_within(0.01).of(0.53)
      expect(status["avg_width"]).to be_a(Integer).and be_positive
    end

    it "has histogram bounds as pg_stats prints them, from the lowest value to the highest" do
      run
      total = stored_table("orders")["columns"]["total_cents"]
      low, high = conn.exec("SELECT min(total_cents), max(total_cents) FROM orders").values.first

      expect(total["histogram_bounds"].size).to eq(101)
      expect(total["histogram_bounds"].values_at(0, -1)).to eq([low, high])
      expect(total["most_common_vals"]).to be_nil
      expect(stored_table("orders")["columns"]["created_at"]["correlation"]).to eq(1.0)
      expect(stored_table("customers")["columns"]["name"]["null_frac"]).to be_within(0.001).of(0.02)
    end

    it "has the table's reltuples and relpages, and its columns in attnum order" do
      run
      orders = stored_table("orders")

      expect(orders).to include("schema" => "public", "reltuples" => 20_000.0,
                                "column_names" => %w[id customer_id status total_cents created_at])
      expect(orders["relpages"]).to be_a(Integer).and be_positive
    end

    # For 3f's heuristic: the string types, a domain over one, and citext.
    # An array of text isn't text itself.
    it "lists the text-like columns, in attnum order" do
      conn.exec(<<~SQL)
        CREATE EXTENSION citext;
        CREATE DOMAIN handle AS varchar(20);
        CREATE TABLE kinds (a text, b varchar(10), c char(2), d citext, e handle, f text[], g int, h name, i jsonb);
      SQL
      run([orders, table("public", "kinds")])

      expect(stored_table("orders")["text_columns"]).to eq(["status"])
      expect(stored_table("kinds")["text_columns"]).to eq(%w[a b c d e h])
    end
  end

  describe "the stored indexes" do
    it "has each valid index's definition and size, and leaves out the invalid one" do
      run
      indexes = stored_table("orders")["indexes"]
      sizes = conn.exec("SELECT relname, pg_relation_size(oid) FROM pg_class WHERE relkind = 'i'").values.to_h

      expect(indexes.map { it["name"] })
        .to eq(%w[orders_customer_id_idx orders_pending_idx orders_pkey orders_status_created_at_idx])
      expect(indexes.to_h { [it["name"], it["size_bytes"]] })
        .to eq(indexes.to_h { [it["name"], Integer(sizes.fetch(it["name"]))] })
      expect(indexes.find { it["name"] == "orders_pending_idx" }["definition"])
        .to eq("CREATE INDEX orders_pending_idx ON public.orders USING btree (created_at) " \
               "WHERE (status = 'pending'::text)")
    end

    it "has the statistics Postgres keeps for an expression index's columns" do
      run
      lower = stored_table("customers")["indexes"].find { it["name"] == "customers_lower_email_idx" }

      expect(lower["columns"].keys).to eq(["lower"])
      expect(lower["columns"]["lower"]["n_distinct"]).to eq(-1.0)
      expect(lower["columns"]["lower"]["histogram_bounds"].first).to start_with("ada.")
    end
  end

  describe "the stored extended statistics" do
    it "has each object's definition, kinds, and data" do
      run
      extended = stored_table("orders")["extended_statistics"]

      expect(extended.size).to eq(1)
      expect(extended.first).to include(
        "schema" => "public", "name" => "orders_status_customer", "kinds" => %w[d f m],
        "definition" => "CREATE STATISTICS public.orders_status_customer ON customer_id, status FROM orders"
      )
      expect(extended.first["n_distinct"]).to match(/\A\{"2, 3": \d+\}\z/)
      expect(extended.first["dependencies"]).to include('"2 => 3"')
      expect(extended.first["most_common_vals"]).to all(match([String, String]))
      expect(extended.first["most_common_vals"].map(&:last)).to include("delivered")
      expect(extended.first["most_common_freqs"].size).to eq(extended.first["most_common_vals"].size)
      expect(extended.first["most_common_base_freqs"].size).to eq(extended.first["most_common_vals"].size)
      expect(extended.first["most_common_val_nulls"]).to all(eq([false, false]))
    end

    it "has an object's definition and kinds, with no data, before ANALYZE fills it" do
      conn.exec("CREATE STATISTICS customers_names (ndistinct) ON name, email FROM customers")
      run

      expect(stored_table("customers")["extended_statistics"]).to eq(
        [{ "schema" => "public", "name" => "customers_names", "kinds" => ["d"],
           "definition" => "CREATE STATISTICS public.customers_names (ndistinct) ON name, email FROM customers",
           **%w[n_distinct dependencies most_common_vals most_common_val_nulls most_common_freqs
                most_common_base_freqs].to_h { [it, nil] } }]
      )
    end
  end

  describe "the statistics shapes" do
    it "builds a TableStatistics for each table from what it read" do
      stats = run.statistics.table(orders)

      expect(stats.reltuples).to eq(20_000.0)
      expect(stats.column_names).to eq(%w[id customer_id status total_cents created_at])
      expect(stats.distinct_count("status")).to eq(6.0)
      expect(stats.value_frequency("status", "delivered")).to be_within(0.001).of(0.71)
      expect(stats.column("created_at").correlation).to eq(1.0)
    end

    it "fills TableStatistics#indexes with the valid indexes, nil for one IndexCandidate can't represent" do
      result = run
      pending = result.statistics.table(orders).indexes["orders_pending_idx"]

      expect(result.statistics.table(orders).indexes.keys)
        .to eq(%w[orders_customer_id_idx orders_pending_idx orders_pkey orders_status_created_at_idx])
      expect([pending.key.map(&:name), pending.predicate, pending.sources.to_a])
        .to eq([["created_at"], "status = 'pending'::text", [:existing]])
      expect(result.statistics.table(orders).indexes["orders_pkey"].unique).to be(true)
      lower = result.statistics.table(customers).indexes["customers_lower_email_idx"]
      expect(lower.key.map(&:expression)).to eq(["lower(email)"])
      expect(result.statistics.table(customers).indexes).to include("customers_email_ff_idx" => nil)
    end

    it "reads back from the store as the same result" do
      result = run

      expect(described_class.load(store)).to eq(result)
    end
  end

  describe "refusals" do
    it "refuses a relation the catalog doesn't have as unknown_relation, storing nothing" do
      error = error_of { run([orders, table("public", "gone")]) }

      expect([error.rule, error.message]).to eq(["unknown_relation", "unknown_relation: public.gone doesn't exist"])
      expect(store.entry?("statistics")).to be(false)
    end

    # pg_stats keeps two rows for an inheritance parent's columns, one for the
    # parent alone and one for its whole tree. v1 doesn't pick between them.
    it "refuses a table with inheritance children as inheritance_parent" do
      conn.exec("CREATE TABLE archived_orders () INHERITS (orders)")

      error = error_of { run }

      expect([error.rule, error.message])
        .to eq(["inheritance_parent", "inheritance_parent: public.orders has inheritance children"])
    end

    # Postgres keeps a tree's inherited = true rows after its last child is
    # dropped, until they're deleted by hand.
    it "reads a former inheritance parent's own statistics, not the rows left from its old tree" do
      conn.exec(<<~SQL)
        CREATE TABLE archived_orders () INHERITS (orders);
        INSERT INTO archived_orders (id, customer_id, status, total_cents, created_at)
        SELECT 100000 + i, 1, 'archived', 1, now() FROM generate_series(1, 30000) AS i;
        ANALYZE orders;
        DROP TABLE archived_orders;
      SQL
      counts = conn.exec(<<~SQL).values.first
        SELECT (SELECT count(*) FROM pg_stats WHERE tablename = 'orders' AND attname = 'status'),
               (SELECT count(*) FROM pg_stats_ext WHERE statistics_name = 'orders_status_customer')
      SQL
      expect(counts).to eq(%w[2 2])

      run

      expect(stored_table("orders")["columns"]["status"]["most_common_vals"]).not_to include("archived")
      expect(stored_table("orders")["extended_statistics"].map { it["most_common_vals"].flatten })
        .to match([satisfy { !it.include?("archived") }])
    end

    it "reads in a read-only transaction and ends it, so a failed read is production_read_failed with its SQLSTATE" do
      failing = Class.new(SimpleDelegator) do
        def exec_params(sql, *) = sql.include?("pg_catalog.pg_stats ") ? super("SELECT 1/0", []) : super
      end.new(conn)

      error = error_of { run(connection: failing) }

      expect([error.rule, error.sqlstate]).to eq(%w[production_read_failed 22012])
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end
  end

  describe "the trust boundary" do
    let(:sentinels) { LeakCheck::Sentinels.new }

    it "keeps the planted values in the store, and out of every error" do
      LeakCheck::Fixture.plant(conn, sentinels)
      run
      customers_stats = stored_table("customers")["columns"]

      # The exposure is real: the sentinels are in the stored statistics.
      expect(stored_table("orders")["columns"]["status"]["most_common_vals"]).to include(sentinels.word)
      expect(stored_table("orders")["columns"]["total_cents"]["most_common_vals"]).to include(sentinels.number.to_s)
      expect(customers_stats["name"]["most_common_vals"]).to include(sentinels.text)
      expect(customers_stats["email"]["histogram_bounds"]).to include(start_with(sentinels.like_prefix))

      s = sentinels
      failing = Class.new(SimpleDelegator) do
        define_method(:exec_params) do |sql, *rest|
          sql.include?("pg_catalog.pg_stats ") ? super("SELECT $1::int", [s.text]) : super(sql, *rest)
        end
      end.new(conn)
      # Postgres's own message quotes the value, so the check below means something.
      expect { failing.exec_params("SELECT pg_catalog.pg_stats ", []) }.to raise_error(PG::Error, /#{s.text}/)
      error = error_of { run(connection: failing) }

      expect([error.rule, error.sqlstate, error.cause]).to eq(["production_read_failed", "22P02", nil])
      expect_no_leaks(sentinels, objects: { error: })
    end
  end
end
