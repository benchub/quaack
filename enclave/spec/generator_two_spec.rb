# frozen_string_literal: true

require "json"
require "quaack/enclave/generator_two"

# The plans are real Postgres 18 output, captured from the sample data by
# spec/fixtures/plans/capture.rb. The statistics below are the real values
# from that same database, which capture.rb writes to statistics.txt.
RSpec.describe Quaack::Enclave::GeneratorTwo do
  let(:enclave) { Quaack::Enclave }

  def table_name(name, schema: "public") = enclave::TableName.new(schema:, name:)

  def column_stats(n_distinct, null_frac, correlation)
    enclave::ColumnStatistics.new(n_distinct:, null_frac:, correlation:)
  end

  def indexes(schema, ddls)
    ddls.transform_values do |ddl|
      enclave::IndexCandidate.from_ddl(ddl.sub(" ON public.", " ON #{schema}."), sources: [:existing])
    end
  end

  def orders_stats(schema: "public", column_names: %w[id customer_id status total_cents created_at],
                   index_ddls: orders_index_ddls)
    columns = {
      "id" => column_stats(-1, 0, 1), "customer_id" => column_stats(2000, 0, 0.014523825),
      "status" => column_stats(6, 0, 0.5291626), "total_cents" => column_stats(-1, 0, 0.0026016105),
      "created_at" => column_stats(-1, 0, 1)
    }.slice(*column_names)
    enclave::TableStatistics.new(name: table_name("orders", schema:), reltuples: 20_000, column_names:, columns:,
                                 indexes: indexes(schema, index_ddls))
  end

  let(:orders_index_ddls) do
    {
      "orders_pkey" => "CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)",
      "orders_customer_id_idx" => "CREATE INDEX orders_customer_id_idx ON public.orders USING btree (customer_id)",
      "orders_status_created_at_idx" =>
        "CREATE INDEX orders_status_created_at_idx ON public.orders USING btree (status, created_at)"
    }
  end

  let(:customers_stats) do
    enclave::TableStatistics.new(
      name: table_name("customers"), reltuples: 2000, column_names: %w[id name email created_at],
      columns: { "id" => column_stats(-1, 0, 1), "name" => column_stats(-0.98, 0.02, -0.0038049063),
                 "email" => column_stats(-1, 0, -0.004259041), "created_at" => column_stats(-1, 0, 1) },
      indexes: indexes("public", {
                         "customers_pkey" => "CREATE UNIQUE INDEX customers_pkey ON public.customers USING btree (id)",
                         "customers_email_key" =>
                           "CREATE UNIQUE INDEX customers_email_key ON public.customers USING btree (email)"
                       })
    )
  end

  let(:statistics) { enclave::Statistics.new(tables: [orders_stats, customers_stats]) }

  def plan(name) = JSON.parse(File.read(File.join(__dir__, "fixtures", "plans", "#{name}.json")))

  def generate(name, stats: statistics, **) = described_class.candidates(plan(name), statistics: stats, **)

  def ddl(name, **) = generate(name, **).map(&:to_ddl)

  def btree(table, columns, rest = "") = "CREATE INDEX ON public.#{table} USING btree (#{columns})#{rest}"

  describe "a Seq Scan whose filter removes most rows" do
    it "proposes a btree on the equality columns, most selective first, and a partial index" do
      # The filter is (status = 'shipped') AND (total_cents = 5100). total_cents
      # is unique, so it removes most rows on its own. status has six values.
      expect(ddl("seq_scan_most_rows")).to eq(
        [btree("orders", "total_cents, status"), btree("orders", "status", " WHERE total_cents = 5100")]
      )
    end

    it "strips alias qualifiers from the columns and the partial predicate, as VERBOSE prints them" do
      expect(ddl("seq_scan_most_rows_verbose")).to eq(
        [btree("orders", "total_cents, status"), btree("orders", "status", " WHERE total_cents = 5100")]
      )
    end

    it "fires when the removed fraction is exactly the threshold, and not above it" do
      # Every row is removed, so the fraction is 1.0.
      expect(ddl("seq_scan_most_rows", most_rows_removed: 1.0)).to include(btree("orders", "total_cents, status"))
      expect(ddl("seq_scan_most_rows", most_rows_removed: 1.0001)).to eq([])
    end

    it "makes a partial index on any constant equality whose selectivity alone meets the threshold" do
      # status = 'shipped' alone removes 1 - 1/6 of the rows, going by pg_stats.
      at_status = ddl("seq_scan_most_rows", most_rows_removed: 1 - (1.0 / 6))
      expect(at_status).to eq(
        [btree("orders", "total_cents, status"),
         btree("orders", "total_cents", " WHERE status = 'shipped'::text"),
         btree("orders", "status", " WHERE total_cents = 5100")]
      )
      expect(ddl("seq_scan_most_rows", most_rows_removed: 1 - (1.0 / 6) + 1e-9)).to eq(
        [btree("orders", "total_cents, status"), btree("orders", "status", " WHERE total_cents = 5100")]
      )
    end

    it "skips the partial index when the filter has no other column to key on" do
      # Inside the InitPlan: Seq Scan on orders, Filter (total_cents = 5100).
      expect(ddl("init_plan")).to eq([btree("orders", "total_cents")])
    end

    it "leaves out a column that isn't in the table's column list" do
      stats = enclave::Statistics.new(tables: [orders_stats(column_names: %w[id customer_id total_cents created_at],
                                                            index_ddls: {}), customers_stats])
      expect(ddl("seq_scan_most_rows", stats:)).to eq([btree("orders", "total_cents")])
    end

    it "keys on a parameter, as a generic plan prints one, but never makes it a partial predicate" do
      # The filter is (status = 'shipped') AND (total_cents = $1).
      expect(ddl("seq_scan_parameter")).to eq([btree("orders", "total_cents, status")])
    end

    it "puts equality columns with unknown selectivity last" do
      no_stats = orders_stats.with(columns: orders_stats.columns.except("total_cents"))
      stats = enclave::Statistics.new(tables: [no_stats, customers_stats])
      expect(ddl("seq_scan_most_rows", stats:)).to eq([btree("orders", "status, total_cents")])
    end
  end

  describe "an Index Scan or Bitmap Heap Scan whose filter removes many rows" do
    let(:extended) do
      [btree("orders", "status, created_at, total_cents"),
       btree("orders", "status, created_at", " INCLUDE (total_cents)")]
    end

    it "extends the Index Scan's index with the filter columns, in the key and as INCLUDE columns" do
      expect(ddl("index_scan_filter")).to eq(extended)
    end

    it "finds a Bitmap Heap Scan's index on its Bitmap Index Scan" do
      expect(ddl("bitmap_heap_scan_filter")).to eq(extended)
    end

    it "proposes plain candidates, not unique ones, from the plan only" do
      candidates = generate("index_scan_filter")
      expect(candidates.map(&:unique)).to eq([false, false])
      expect(candidates.map(&:sources)).to eq([Set[:plan], Set[:plan]])
    end

    it "fires at exactly the fraction and row thresholds, and not above either" do
      # 2,165 of 2,400 rows are removed.
      expect(ddl("index_scan_filter", many_rows_removed: 2165 / 2400.0, many_rows_min: 2165)).to eq(extended)
      expect(ddl("index_scan_filter", many_rows_removed: (2165 / 2400.0) + 1e-9)).to eq([])
      expect(ddl("index_scan_filter", many_rows_min: 2166)).to eq([])
    end

    it "counts the rows removed over every loop" do
      # Inside SubPlan 1: 8 rows removed per loop, over 199 loops.
      expect(ddl("sub_plan")).to eq(
        [btree("orders", "customer_id, total_cents"), btree("orders", "customer_id", " INCLUDE (total_cents)")]
      )
      expect(ddl("sub_plan", many_rows_min: (8 * 199) + 1)).to eq([])
    end

    it "skips an index its statistics can't represent, or doesn't list" do
      unrepresentable = orders_index_ddls.merge(
        "orders_status_created_at_idx" => "CREATE INDEX x ON public.orders USING btree (lower(status))"
      )
      [unrepresentable, orders_index_ddls.except("orders_status_created_at_idx")].each do |index_ddls|
        stats = enclave::Statistics.new(tables: [orders_stats(index_ddls:), customers_stats])
        expect(ddl("index_scan_filter", stats:)).to eq([])
      end
    end
  end

  describe "a Sort" do
    it "puts the sort keys, with their direction, after the equality columns" do
      expect(ddl("sort_under_limit")).to eq([btree("orders", "customer_id, created_at DESC")])
    end

    it "keeps an explicit nulls ordering" do
      expect(ddl("sort_external_merge")).to eq([btree("orders", "status, total_cents DESC NULLS LAST, id")])
    end

    it "treats an Incremental Sort the same way" do
      expect(ddl("incremental_sort")).to eq([btree("orders", "status, total_cents")])
    end
  end

  describe "a Nested Loop with an expensive inner side" do
    it "indexes the inner table's join key plus its filter columns" do
      # The inner Materialize returns 71 rows on each of 200 loops. The outer
      # Seq Scan on orders removes 99% of its rows, so it gets a btree too.
      expect(ddl("nested_loop_inner")).to eq([btree("customers", "id, created_at"), btree("orders", "status")])
    end

    it "fires at exactly the threshold, and not above it" do
      expect(ddl("nested_loop_inner", expensive_inner_rows: 71 * 200)).to include(btree("customers", "id, created_at"))
      expect(ddl("nested_loop_inner", expensive_inner_rows: (71 * 200) + 1)).to eq([btree("orders", "status")])
    end
  end

  describe "a Hash Join with a large inner build" do
    it "indexes the inner side's join key when the hash spills into more than one batch" do
      expect(ddl("hash_join_batches")).to eq([btree("customers", "id")])
    end

    it "also fires on the Hash node's row count, at exactly the threshold" do
      # Two batches and 2,000 rows.
      expect(ddl("hash_join_batches", large_hash_batches: 3)).to eq([])
      expect(ddl("hash_join_batches", large_hash_batches: 3, large_hash_rows: 2000)).to eq([btree("customers", "id")])
      expect(ddl("hash_join_batches", large_hash_batches: 3, large_hash_rows: 2001)).to eq([])
    end
  end

  describe "a BitmapOr or BitmapAnd of single-column indexes" do
    it "proposes one composite index on their columns" do
      expect(ddl("bitmap_or")).to eq([btree("customers", "id, email")])
      expect(ddl("bitmap_and")).to eq([btree("orders", "customer_id, id")])
    end
  end

  describe "an aggregate" do
    it "indexes the GROUP BY keys of a hash aggregate" do
      expect(ddl("hash_aggregate")).to eq([btree("orders", "status, total_cents")])
    end

    it "indexes the GROUP BY keys of a sorted aggregate once, though its Sort proposes the same index" do
      candidates = generate("group_aggregate_sort")
      expect(candidates.map(&:to_ddl)).to eq([btree("customers", "name, created_at")])
      expect(candidates.first.sources).to eq(Set[:plan])
    end
  end

  describe "plans with nothing to propose" do
    it "skips a sorted aggregate that reads an index in order, with no Sort" do
      expect(ddl("group_aggregate_presorted")).to eq([])
    end

    it "skips heap fetches on an Index Only Scan" do
      expect(ddl("index_only_scan_heap_fetches")).to eq([])
    end

    it "proposes nothing for a primary key lookup" do
      expect(ddl("primary_key_lookup")).to eq([])
    end
  end

  describe "mapping plan relations to tables" do
    let(:archive) { orders_stats(schema: "archive") }

    it "skips a relation whose name is in more than one schema, unless schemas: settles it" do
      stats = enclave::Statistics.new(tables: [orders_stats, archive, customers_stats])
      expect(ddl("init_plan", stats:)).to eq([])
      expect(ddl("init_plan", stats:, schemas: %w[public archive])).to eq([])
      expect(ddl("init_plan", stats:, schemas: ["archive"])).to eq(
        ["CREATE INDEX ON archive.orders USING btree (total_cents)"]
      )
    end

    it "uses the Schema that VERBOSE prints" do
      stats = enclave::Statistics.new(tables: [orders_stats, archive, customers_stats])
      expect(ddl("seq_scan_most_rows_verbose", stats:)).to eq(
        [btree("orders", "total_cents, status"), btree("orders", "status", " WHERE total_cents = 5100")]
      )
    end

    it "skips a relation with no statistics" do
      expect(ddl("init_plan", stats: enclave::Statistics.new(tables: [customers_stats]))).to eq([])
    end
  end

  describe "its output" do
    it "is a frozen array, the same on every call" do
      first = generate("nested_loop_inner")
      expect(first).to be_frozen
      expect(generate("nested_loop_inner")).to eq(first)
    end
  end

  describe "bad input" do
    it "refuses anything but the parsed EXPLAIN JSON array" do
      [{ "Plan" => {} }, [], [{ "Plan" => "x" }], [{}], nil].each do |bad|
        expect { described_class.candidates(bad, statistics:) }.to raise_error(ArgumentError, /EXPLAIN/), bad.inspect
      end
    end

    it "refuses a plan node that isn't an object" do
      expect { described_class.candidates([{ "Plan" => { "Plans" => ["x"] } }], statistics:) }
        .to raise_error(ArgumentError, /plan node/)
    end

    it "refuses a threshold it doesn't know" do
      expect { generate("init_plan", most_rows: 0.5) }.to raise_error(ArgumentError, /unknown thresholds: most_rows/)
    end

    it "refuses statistics that aren't a Statistics, and schemas that aren't names" do
      expect { described_class.candidates(plan("init_plan"), statistics: {}) }
        .to raise_error(ArgumentError, /Statistics/)
      expect { described_class.candidates(plan("init_plan"), statistics:, schemas: "public") }
        .to raise_error(ArgumentError, /schemas/)
    end

    it "refuses a threshold that isn't a number in range" do
      [{ most_rows_removed: -0.5 }, { many_rows_removed: -0.1 }, { many_rows_min: -1 }, { large_hash_rows: "big" },
       { expensive_inner_rows: nil }, { large_hash_batches: Float::NAN }].each do |bad|
        expect { generate("init_plan", **bad) }.to raise_error(ArgumentError, /#{bad.keys.first}/), bad.inspect
      end
    end
  end

  # README, "Trust boundary": a partial-index candidate holds a real literal,
  # so it's value-class data. Nothing here sends it anywhere, but no error
  # message or inspect output may carry a filter literal.
  describe "filter literals" do
    let(:sentinels) { %w[quaack-sentinel-email quaack-sentinel-name] }

    it "reach the partial predicates, so the checks below have something to catch" do
      candidates = generate("sentinel_literals")
      expect(candidates.map(&:to_ddl).join).to include(*sentinels)
    end

    it "never show up in the candidates' inspect or to_s" do
      shown = generate("sentinel_literals").then { |c| [c.inspect, c.to_s, c.map(&:inspect).join] }.join
      expect(shown).to include("<redacted>")
      sentinels.each { |s| expect(shown).not_to include(s) }
    end

    it "never show up in the inspect or to_s of the plan nodes and conjuncts the generator builds" do
      node = enclave.const_get(:PlanNode).new(plan("sentinel_literals").first["Plan"])
      columns = enclave.const_get(:PlanColumns).new(node.subtree, statistics, nil)
      conjuncts = columns.conjuncts(node, ["Filter"], "c")
      expect(conjuncts.map(&:kind)).to eq(%i[constant constant])
      shown = [node, columns, *conjuncts].flat_map { |o| [o.inspect, o.to_s] }.join
      expect(shown).to include("Seq Scan")
      sentinels.each { |s| expect(shown).not_to include(s) }
    end

    it "never show up in an error message" do
      explain = plan("sentinel_literals")
      explain.first["Plan"]["Plans"] = "not a list"
      bad_inputs = [explain, [plan("sentinel_literals").first.to_a], plan("sentinel_literals").first]
      bad_inputs.each do |bad|
        expect { described_class.candidates(bad, statistics:) }
          .to raise_error(ArgumentError) { |e| sentinels.each { |s| expect(e.message).not_to include(s) } }
      end
      expect { described_class.candidates(plan("sentinel_literals"), statistics: sentinels) }
        .to raise_error(ArgumentError) { |e| sentinels.each { |s| expect(e.message).not_to include(s) } }
    end
  end

  # The plan strings come from Postgres, so the fixtures never hit these
  # guards. They're checked on the strings directly.
  describe "reading plan strings" do
    let(:expression) { enclave.const_get(:PlanExpression) }

    it "reads a sort key's direction and nulls ordering" do
      _, direction, nulls = expression.sort_key("o.total_cents DESC NULLS LAST")
      expect([direction, nulls]).to eq(%i[desc last])
      expect(expression.sort_key("total_cents").drop(1)).to eq([:asc, nil])
    end

    it "gives nothing for a string that's more than one key or condition" do
      expect(expression.sort_key("total_cents USING >")).to be_nil
      expect(expression.sort_key("a, b")).to be_nil
      expect(expression.sort_key("a LIMIT 1")).to be_nil
      expect(expression.conjuncts("(a = 1) ORDER BY b")).to eq([])
      expect(expression.conjuncts("(a = 1); SELECT 1")).to eq([])
      expect(expression.conjuncts("(id = (InitPlan 1).col1)")).to eq([])
    end

    it "splits only a top-level AND" do
      expect(expression.conjuncts("((a = 1) AND (b = 2))").size).to eq(2)
      expect(expression.conjuncts("((a = 1) OR (b = 2))").size).to eq(1)
    end

    it "drops every qualifier from a predicate, keeping its casts" do
      node = expression.conjuncts("(s.o.status = 'x'::text)").first
      expect(expression.unqualified_sql(node)).to eq("status = 'x'::text")
    end
  end
end
