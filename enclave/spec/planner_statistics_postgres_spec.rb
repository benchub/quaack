# frozen_string_literal: true

require "delegate"
require "tmpdir"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/store"

# DESIGN.md's statistics against the harness's sample schema (spec/support/postgres),
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

    # For classify's heuristic: the string types, a domain over one, and citext.
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

    # For classify: a column's MCV values may leave only when its type is
    # text-like or on the allowlist (numbers, money, oid, boolean, the date
    # and time types, uuid, an enum), or a domain over one at any depth.
    it "lists the columns whose values may leave: text-like and allowlisted types, in attnum order" do
      conn.exec(<<~SQL)
        CREATE TYPE mood AS ENUM ('sad', 'fine');
        CREATE DOMAIN handle AS varchar(20);
        CREATE DOMAIN qty AS int;
        CREATE DOMAIN calm AS mood;
        CREATE DOMAIN deep_calm AS calm;
        CREATE TABLE plain (a text, b handle, c smallint, d integer, e bigint, f numeric(10, 2), g real,
                            h double precision, i money, j oid, k boolean, l date, m time, n timetz,
                            o timestamp(3), p timestamptz, q interval, r uuid, s mood, t qty, u deep_calm);
      SQL
      run([orders, table("public", "plain")])

      expect(stored_table("orders")["sendable_columns"]).to eq(%w[id customer_id status total_cents created_at])
      expect(stored_table("plain")["sendable_columns"]).to eq(("a".."u").to_a)
    end

    # Every type that isn't text-like or on the allowlist is left out:
    # structured types (json, jsonb, arrays, hstore, xml, tsvector, tsquery,
    # composites, ranges, multiranges), bytea, the geometric and network
    # types, bit strings, "char", and anything else, such as jsonpath or
    # pg_lsn, and a domain over any of them at any depth. An array of an
    # allowlisted type is left out too.
    it "leaves out every other type, and a domain over one" do
      conn.exec(<<~SQL)
        CREATE SCHEMA ext;
        CREATE EXTENSION hstore SCHEMA ext;
        CREATE TYPE pair AS (label text, n int);
        CREATE TYPE mood AS ENUM ('sad', 'fine');
        CREATE DOMAIN blob AS bytea;
        CREATE DOMAIN deep_blob AS blob;
        CREATE DOMAIN ints AS int[];
        CREATE DOMAIN prefs AS jsonb;
        CREATE DOMAIN deep_prefs AS prefs;
        CREATE DOMAIN tag_map AS ext.hstore;
        CREATE DOMAIN span AS int4range;
        CREATE DOMAIN pair_domain AS pair;
        CREATE DOMAIN qty AS int;
        CREATE TABLE others (a bytea, b point, c line, d lseg, e box, f path, g polygon, h circle, i inet,
                             j cidr, k macaddr, l macaddr8, m bit(3), n varbit, o "char", p json, q jsonb,
                             r int[], s uuid[], t mood[], u qty[], v deep_blob, w ints, x deep_prefs,
                             y ext.hstore, z tag_map, aa xml, ab tsvector, ac tsquery, ad pair, ae pair_domain,
                             af customers, ag int4range, ah tstzrange, ai int4multirange, aj span, ak jsonpath,
                             al pg_lsn, am regclass, an xid, ao tid, ap int);
      SQL
      run([table("public", "others")])

      expect(stored_table("others")["sendable_columns"]).to eq(["ap"])
    end

    # The catalog query names every operator it compares with, so an
    # operator planted ahead of pg_catalog's on the search_path can't make a
    # type look text-like, allowlisted, an enum, or a clock type. These ones say yes to
    # everything: an oid against a regtype, and one "char" against another
    # (typcategory and typtype).
    it "isn't fooled by an operator planted ahead of pg_catalog's" do
      conn.exec(<<~SQL)
        CREATE TABLE odd (a bytea, b inet, c int);
        CREATE FUNCTION public.yes_oid(pg_catalog.oid, pg_catalog.regtype) RETURNS pg_catalog.bool
          LANGUAGE sql AS $$ SELECT true $$;
        CREATE FUNCTION public.yes_char(pg_catalog."char", pg_catalog."char") RETURNS pg_catalog.bool
          LANGUAGE sql AS $$ SELECT true $$;
        CREATE OPERATOR public.= (LEFTARG = pg_catalog.oid, RIGHTARG = pg_catalog.regtype, FUNCTION = public.yes_oid);
        CREATE OPERATOR public.= (LEFTARG = pg_catalog."char", RIGHTARG = pg_catalog."char",
                                  FUNCTION = public.yes_char);
        SET search_path = public, pg_catalog;
      SQL
      run([table("public", "odd")])

      expect(stored_table("odd")).to include("text_columns" => [], "sendable_columns" => ["c"], "clock_columns" => {})
    end

    # For clock-anchor's clock literals: the date and timestamp columns, by their
    # type, a domain's by its base type.
    it "maps the date and timestamp columns to their types" do
      conn.exec(<<~SQL)
        CREATE DOMAIN day AS date;
        CREATE TABLE times (a date, b timestamp(3), c timestamptz, d day, e time, f text, g date[]);
      SQL
      run([table("public", "times")])

      expect(stored_table("times")["clock_columns"])
        .to eq("a" => "date", "b" => "timestamp", "c" => "timestamptz", "d" => "date")
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

  # Every catalog read names pg_catalog's operator for each comparison, so
  # operators planted ahead of pg_catalog's on the search_path can't change
  # what it reads. These say no to everything: one oid against another (the
  # joins, the inheritance check, and the table, index, and statistics-object
  # lookups) and one name against another (the schema, table, and
  # statistics-object names). They say no rather than yes, so a bare
  # operator fails fast instead of crawling the whole catalog. An
  # inheritance parent must still be refused.
  describe "the catalog reads" do
    let(:other_store) { Quaack::Enclave::Store.create(base: @base) }

    it "read the same entry with no-to-everything operators planted ahead of pg_catalog's" do
      conn.exec("CREATE TABLE parent (a int); CREATE TABLE child () INHERITS (parent)")
      described_class.run(store: other_store, relations: [customers, orders], connection: conn)
      want = other_store.read("statistics")["tables"]
      conn.exec(<<~SQL)
        CREATE FUNCTION public.no_oid(pg_catalog.oid, pg_catalog.oid) RETURNS pg_catalog.bool
          LANGUAGE sql AS $$ SELECT false $$;
        CREATE FUNCTION public.no_name(pg_catalog.name, pg_catalog.name) RETURNS pg_catalog.bool
          LANGUAGE sql AS $$ SELECT false $$;
        CREATE OPERATOR public.= (LEFTARG = pg_catalog.oid, RIGHTARG = pg_catalog.oid, FUNCTION = public.no_oid);
        CREATE OPERATOR public.= (LEFTARG = pg_catalog.name, RIGHTARG = pg_catalog.name, FUNCTION = public.no_name);
        SET search_path = public, pg_catalog;
      SQL
      run

      expect(want.map { [it["indexes"].size, it["extended_statistics"].size] }).to eq([[4, 0], [4, 1]])
      expect(store.read("statistics")["tables"]).to eq(want)
      expect(error_of { run([table("public", "parent")]) }.rule).to eq("inheritance_parent")
    end

    # Each ORDER BY names pg_catalog's "C" collation, so an ICU "C" planted
    # ahead of it can't reorder the columns, indexes, or statistics
    # objects. ICU puts "apple" before "Zed", and "public" before "Zs", and
    # pg_catalog's "C" the reverse. JSON text, since a Hash's == ignores key
    # order.
    it "read the same entry, in the same order, with a collation planted ahead of pg_catalog's" do
      conn.exec(<<~SQL)
        CREATE TABLE fruit ("Zed" int, apple int);
        CREATE INDEX "Zed_idx" ON fruit ("Zed");
        CREATE INDEX apple_idx ON fruit (apple);
        CREATE STATISTICS "Zed_stats" ON "Zed", apple FROM fruit;
        CREATE STATISTICS apple_stats ON "Zed", apple FROM fruit;
        CREATE SCHEMA "Zs";
        CREATE STATISTICS "Zs".other_stats ON "Zed", apple FROM fruit;
        INSERT INTO fruit SELECT i, i FROM generate_series(1, 100) AS i;
        ANALYZE fruit;
      SQL
      fruit = table("public", "fruit")
      described_class.run(store: other_store, relations: [fruit], connection: conn)
      want = JSON.generate(other_store.read("statistics")["tables"])
      conn.exec(<<~SQL)
        CREATE COLLATION public."C" (provider = icu, locale = 'und');
        SET search_path = public, pg_catalog;
      SQL
      run([fruit])

      expect(conn.exec(%(SELECT x FROM (VALUES ('Zed'), ('apple')) v(x) ORDER BY x COLLATE "C")).column_values(0))
        .to eq(%w[apple Zed])
      expect(want).to include('"columns":{"Zed":')
      expect(want.index('"Zed_idx"')).to be < want.index('"apple_idx"')
      expect(want.index('"Zs"')).to be < want.index('"Zed_stats"')
      expect(want.index('"Zed_stats"')).to be < want.index('"apple_stats"')
      expect(JSON.generate(store.read("statistics")["tables"])).to eq(want)
    end

    # Every function and type they name is pg_catalog's too, so one planted
    # ahead of it can't write what they read. These write a sentinel: an
    # array_to_json, and a text type with casts from the types the reads
    # cast to text.
    let(:sentinel) { LeakCheck::Sentinels.claim { "sentinel#{SecureRandom.hex(6)}" } }

    def unplanted_tables
      described_class.run(store: other_store, relations: [customers, orders], connection: conn)
      other_store.read("statistics")["tables"]
    end

    def planted_tables
      run
      JSON.generate(store.read("statistics")["tables"])
    end

    def planted_read(sql)
      want = unplanted_tables
      conn.exec("#{sql}\nSET search_path = public, pg_catalog;")
      got = planted_tables

      expect(got).not_to include(sentinel)
      # With a text type ahead of pg_catalog's, pg_get_indexdef names
      # pg_catalog's in a predicate's cast: the same index.
      expect(JSON.parse(got.gsub("::pg_catalog.text", "::text"))).to eq(want)
    end

    it "read the same entry with an array_to_json planted ahead of pg_catalog's" do
      planted_read(<<~SQL)
        CREATE FUNCTION public.array_to_json(pg_catalog.anyarray) RETURNS pg_catalog.json
          LANGUAGE sql AS $$ SELECT pg_catalog.to_json(ARRAY['#{sentinel}']) $$;
      SQL
    end

    it "read the same entry with a text type planted ahead of pg_catalog's" do
      planted_read(<<~SQL)
        CREATE TYPE public.text AS ENUM ('{#{sentinel}}', '{0.5}');
        CREATE FUNCTION public.leak_kinds(pg_catalog."char"[]) RETURNS public.text
          LANGUAGE sql AS $$ SELECT '{#{sentinel}}'::public.text $$;
        CREATE FUNCTION public.leak_freqs(pg_catalog.float4[]) RETURNS public.text
          LANGUAGE sql AS $$ SELECT '{0.5}'::public.text $$;
        CREATE FUNCTION public.leak_ndistinct(pg_catalog.pg_ndistinct) RETURNS public.text
          LANGUAGE sql AS $$ SELECT '{#{sentinel}}'::public.text $$;
        CREATE FUNCTION public.leak_dependencies(pg_catalog.pg_dependencies) RETURNS public.text
          LANGUAGE sql AS $$ SELECT '{#{sentinel}}'::public.text $$;
        CREATE CAST (pg_catalog."char"[] AS public.text) WITH FUNCTION public.leak_kinds;
        CREATE CAST (pg_catalog.float4[] AS public.text) WITH FUNCTION public.leak_freqs;
        CREATE CAST (pg_catalog.pg_ndistinct AS public.text) WITH FUNCTION public.leak_ndistinct;
        CREATE CAST (pg_catalog.pg_dependencies AS public.text) WITH FUNCTION public.leak_dependencies;
      SQL
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
