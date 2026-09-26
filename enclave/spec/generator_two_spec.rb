# frozen_string_literal: true

require "json"
require "pp"
require "quaack/enclave/generator_two"
require "quaack/enclave/pg_array"

# The plans are real Postgres 18 output, captured from the test harness's
# sample data by spec/fixtures/plans/capture.rb. The statistics are read from
# statistics.txt, which capture.rb writes from the same database: pg_class,
# pg_stats (MCV lists included), and pg_get_indexdef.

# Each line of statistics.txt, split on |.
GENERATOR_TWO_CAPTURED = File.readlines(File.join(__dir__, "fixtures", "plans", "statistics.txt"), chomp: true)
                             .map { |line| line.split("|", -1) }.freeze

RSpec.describe Quaack::Enclave::GeneratorTwo do
  let(:enclave) { Quaack::Enclave }

  def table_name(name, schema: "public") = enclave::TableName.new(schema:, name:)

  def indexes(schema, ddls)
    ddls.transform_values do |ddl|
      enclave::IndexCandidate.from_ddl(ddl.sub(" ON public.", " ON #{schema}."), sources: [:existing])
    end
  end

  def array(text) = (enclave.const_get(:PgArray).parse(text) unless text.empty?)

  def captured_columns(table)
    GENERATOR_TWO_CAPTURED.select { |kind, name| kind == "pg_stats" && name == table }.to_h do |row|
      _, _, column, n_distinct, null_frac, correlation, vals, freqs = row
      [column, enclave::ColumnStatistics.new(
        n_distinct: Float(n_distinct), null_frac: Float(null_frac), correlation: Float(correlation, exception: false),
        most_common_vals: array(vals), most_common_freqs: array(freqs)&.map { |f| Float(f) }
      )]
    end
  end

  def captured_index_ddls(table)
    GENERATOR_TWO_CAPTURED.select { |kind, _, ddl| kind == "indexdef" && ddl.include?(" ON public.#{table} ") }
                          .to_h { |_, name, ddl| [name, ddl] }
  end

  def captured_reltuples(table)
    Float(GENERATOR_TWO_CAPTURED.find { |kind, name| kind == "reltuples" && name == table }[2])
  end

  def captured_table(table, column_names, schema: "public", index_ddls: captured_index_ddls(table))
    enclave::TableStatistics.new(name: table_name(table, schema:), reltuples: captured_reltuples(table), column_names:,
                                 columns: captured_columns(table).slice(*column_names),
                                 indexes: indexes(schema, index_ddls))
  end

  def orders_stats(schema: "public", column_names: %w[id customer_id status total_cents created_at],
                   index_ddls: orders_index_ddls)
    captured_table("orders", column_names, schema:, index_ddls:)
  end

  let(:orders_index_ddls) { captured_index_ddls("orders") }

  let(:customers_stats) { captured_table("customers", %w[id name email created_at]) }

  let(:statistics) { enclave::Statistics.new(tables: [orders_stats, customers_stats]) }

  def plan(name) = JSON.parse(File.read(File.join(__dir__, "fixtures", "plans", "#{name}.json")))

  def generate(name, stats: statistics, **) = described_class.candidates(plan(name), statistics: stats, **)

  def ddl(name, **) = generate(name, **).map(&:to_ddl)

  def btree(table, columns, rest = "") = "CREATE INDEX ON public.#{table} USING btree (#{columns})#{rest}"

  describe "a Seq Scan whose filter removes most rows" do
    # The filter is (created_at > ...) AND (status = 'shipped') AND
    # (total_cents = 5100). total_cents is unique, so it removes most rows on
    # its own. status has six values.
    let(:seq_scan) do
      [btree("orders", "total_cents, status"), btree("orders", "status, created_at", " WHERE total_cents = 5100")]
    end

    it "proposes a btree on the equality columns, most selective first, and a partial index" do
      expect(ddl("seq_scan_most_rows")).to eq(seq_scan)
    end

    it "strips alias qualifiers from the columns and the partial predicate, as VERBOSE prints them" do
      expect(ddl("seq_scan_most_rows_verbose")).to eq(seq_scan)
    end

    it "fires when the removed fraction is exactly the threshold, and not above it" do
      # Every row is removed, so the fraction is 1.0.
      expect(ddl("seq_scan_most_rows", most_rows_removed: 1.0)).to include(btree("orders", "total_cents, status"))
      expect(ddl("seq_scan_most_rows", most_rows_removed: 1.0001)).to eq([])
    end

    it "makes a partial index on a rare value of a low-cardinality column, by its MCV frequency" do
      # Filter (total_cents > 100) AND (status = 'failed'). 'failed' is 1% of
      # the rows, though status has only six values.
      expect(ddl("seq_scan_rare_value")).to eq(
        [btree("orders", "status"), btree("orders", "total_cents", " WHERE status = 'failed'::text")]
      )
    end

    it "makes the partial index when the value's frequency leaves exactly the threshold, and not above it" do
      # 'failed' has an MCV frequency of 0.01, and the scan removes 99%.
      partial = btree("orders", "total_cents", " WHERE status = 'failed'::text")
      expect(ddl("seq_scan_rare_value", most_rows_removed: 1 - 0.01)).to include(partial)
      expect(ddl("seq_scan_rare_value", most_rows_removed: 1 - 0.01 + 1e-9)).not_to include(partial)
    end

    it "makes a partial index on a common value only when the threshold allows it" do
      # 'shipped' has an MCV frequency of 0.12.
      expect(ddl("seq_scan_most_rows", most_rows_removed: 0.88)).to eq(
        [btree("orders", "total_cents, status"),
         btree("orders", "total_cents, created_at", " WHERE status = 'shipped'::text"),
         btree("orders", "status, created_at", " WHERE total_cents = 5100")]
      )
    end

    it "still proposes a partial on a unique column's value, leaving 5a-3 to drop it" do
      # total_cents has no MCV list, so its frequency is 1/20,000.
      expect(ddl("seq_scan_most_rows")).to include(btree("orders", "status, created_at", " WHERE total_cents = 5100"))
    end

    # pg_query deparses a type modifier that isn't a constant as nothing,
    # so this conjunct's predicate can't be written faithfully. Postgres
    # never prints one, so the captured Filter is edited by hand.
    it "skips a partial index whose predicate pg_query can't deparse faithfully, and keeps the rest" do
      explain = plan("seq_scan_rare_value")
      explain.first["Plan"]["Filter"] = "((total_cents > 100) AND ((status)::mytype(lower('bob')) = 'failed'::text))"
      expect(described_class.candidates(explain, statistics:).map(&:to_ddl)).to eq([btree("orders", "status")])
    end

    it "makes no partial index on a column with no pg_stats row" do
      no_status = orders_stats.with(columns: orders_stats.columns.except("status"))
      stats = enclave::Statistics.new(tables: [no_status, customers_stats])
      expect(ddl("seq_scan_rare_value", stats:)).to eq([btree("orders", "status")])
    end

    it "skips the partial index when the filter has no other column to key on" do
      # Inside the InitPlan: Seq Scan on orders, Filter (total_cents = 5100).
      expect(ddl("init_plan")).to eq([btree("orders", "total_cents")])
    end

    it "leaves out a column that isn't in the table's column list" do
      stats = enclave::Statistics.new(tables: [orders_stats(column_names: %w[id customer_id total_cents created_at],
                                                            index_ddls: {}), customers_stats])
      expect(ddl("seq_scan_most_rows", stats:)).to eq(
        [btree("orders", "total_cents"), btree("orders", "created_at", " WHERE total_cents = 5100")]
      )
    end

    it "keys on a parameter, as a generic plan prints one, but never makes it a partial predicate" do
      # The filter is (status = 'shipped') AND (total_cents = $1).
      expect(ddl("seq_scan_parameter")).to eq([btree("orders", "total_cents, status")])
    end

    it "proposes nothing for a filter with no constant equality" do
      # The inner Seq Scan on customers removes 96% of its rows, but its
      # Filter is only (created_at < ...).
      expect(ddl("nested_loop_inner", expensive_inner_rows: 1_000_000)).to eq([btree("orders", "status")])
    end

    it "puts equality columns with unknown selectivity last, and makes no partial index on them" do
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

    it "finds a Bitmap Heap Scan's index on its Bitmap Index Scan, adding a column the Filter names twice once" do
      # Filter (total_cents > 100) AND (total_cents < 5000).
      expect(ddl("bitmap_heap_scan_filter")).to eq(extended)
    end

    it "proposes nothing when every Filter column is already in the index key" do
      # Filter (date_trunc('day', created_at) = ...) on orders_status_created_at_idx.
      expect(ddl("index_scan_key_filter")).to eq([])
    end

    it "finds the Bitmap Index Scan behind an InitPlan in the heap scan's children" do
      expect(ddl("bitmap_heap_scan_init_plan")).to eq(extended)
    end

    it "extends a unique index into plain candidates from the plan only, constant equality columns first" do
      # Index Scan on customers_pkey, Filter (created_at > ...) AND
      # (name = ...) AND ((id % 2) = 0). id is already in the key.
      candidates = generate("index_scan_unique_filter")
      expect(candidates.map(&:to_ddl)).to eq(
        [btree("customers", "id, name, created_at"), btree("customers", "id", " INCLUDE (name, created_at)")]
      )
      expect(candidates.map(&:unique)).to eq([false, false])
      expect(candidates.map(&:sources)).to eq([Set[:plan], Set[:plan]])
    end

    it "moves a filter column out of the index's INCLUDE columns when it joins the key" do
      index_ddls = orders_index_ddls.merge(
        "orders_status_created_at_idx" =>
          "CREATE INDEX orders_status_created_at_idx ON public.orders USING btree (status, created_at) " \
          "INCLUDE (total_cents)"
      )
      stats = enclave::Statistics.new(tables: [orders_stats(index_ddls:), customers_stats])
      expect(ddl("index_scan_filter", stats:)).to eq(extended)
    end

    it "counts the rows the index recheck removes, as a lossy bitmap does" do
      # A parallel Bitmap Heap Scan over three loops, removing 45,655 rows per
      # loop in the recheck and 90,000 in the Filter.
      events = enclave::TableStatistics.new(
        name: table_name("events"), reltuples: 1_000_000, column_names: %w[id kind], columns: {},
        indexes: indexes("public", "events_kind_idx" =>
                                     "CREATE INDEX events_kind_idx ON public.events USING btree (kind)")
      )
      stats = enclave::Statistics.new(tables: [events])
      lossy = [btree("events", "kind, id"), btree("events", "kind", " INCLUDE (id)")]
      expect(ddl("bitmap_heap_scan_lossy", stats:, many_rows_min: (45_655 + 90_000) * 3)).to eq(lossy)
      expect(ddl("bitmap_heap_scan_lossy", stats:, many_rows_min: ((45_655 + 90_000) * 3) + 1)).to eq([])
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
        "orders_status_created_at_idx" => "CREATE INDEX x ON public.orders USING btree (status) WITH (fillfactor='70')"
      )
      [unrepresentable, orders_index_ddls.except("orders_status_created_at_idx")].each do |index_ddls|
        stats = enclave::Statistics.new(tables: [orders_stats(index_ddls:), customers_stats])
        expect(ddl("index_scan_filter", stats:)).to eq([])
      end
    end

    it "extends an expression index in use, keeping its expression (20260922-33)" do
      index_ddls = orders_index_ddls.merge(
        "orders_status_created_at_idx" => "CREATE INDEX x ON public.orders USING btree (lower(status))"
      )
      stats = enclave::Statistics.new(tables: [orders_stats(index_ddls:), customers_stats])
      expect(ddl("index_scan_filter", stats:)).to eq(
        ["CREATE INDEX ON public.orders USING btree (lower(status), total_cents)",
         "CREATE INDEX ON public.orders USING btree (lower(status)) INCLUDE (total_cents)"]
      )
    end

    it "extends only a btree index, since other methods can't take the columns" do
      # SubPlan 1's Bitmap Heap Scan uses orders_customer_id_idx. A hash index
      # can't have a second key column or INCLUDE columns.
      index_ddls = orders_index_ddls.merge(
        "orders_customer_id_idx" => "CREATE INDEX orders_customer_id_idx ON public.orders USING hash (customer_id)"
      )
      stats = enclave::Statistics.new(tables: [orders_stats(index_ddls:), customers_stats])
      expect(ddl("sub_plan", stats:)).to eq([])
    end
  end

  describe "a Sort" do
    it "puts the sort keys, with their direction, after the equality columns" do
      expect(ddl("sort_under_limit")).to eq([btree("orders", "customer_id, created_at DESC")])
    end

    it "keeps an explicit nulls ordering" do
      expect(ddl("sort_external_merge")).to eq([btree("orders", "status, total_cents DESC NULLS LAST, id")])
    end

    it "puts the most selective equality column first" do
      # Filter (status = 'shipped'), Recheck Cond (customer_id = 5).
      expect(ddl("sort_two_equalities")).to eq([btree("orders", "customer_id, status, created_at")])
    end

    it "treats an Incremental Sort the same way" do
      expect(ddl("incremental_sort")).to eq([btree("orders", "status, total_cents")])
    end

    it "stops the sort keys at the first one from another table" do
      # Sort Key: c.name, o.total_cents, c.created_at.
      expect(ddl("sort_two_tables")).to eq([btree("customers", "name")])
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

    it "finds the join in the inner Index Scan's Index Cond, and puts constant equality columns first" do
      # Inner: Index Scan on orders, Index Cond (customer_id = c.id), Filter
      # (total_cents > 1000) AND (status = 'shipped'). It returns no rows, so
      # only a zero threshold fires. The outer Seq Scan on customers removes
      # all but one row.
      expect(ddl("nested_loop_parameterized", expensive_inner_rows: 0)).to eq(
        [btree("orders", "customer_id, status, total_cents"), btree("customers", "name")]
      )
      expect(ddl("nested_loop_parameterized")).to eq([btree("customers", "name")])
    end

    it "leaves a Merge Join alone, even with a large inner side and a join equality in its Join Filter" do
      # Merge Join, Join Filter (o.status = c.name), inner Index Scan on
      # orders returning 20,000 rows.
      expect(ddl("merge_join_filter")).to eq([])
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

    it "counts a Parallel Hash's rows over all its participants" do
      # Two workers and the leader each report 83,333.33 of the 250,000 rows,
      # in one batch.
      tables = { "events" => %w[id kind], "visits" => %w[id event_id] }.map do |name, column_names|
        enclave::TableStatistics.new(name: table_name(name), reltuples: 250_000, column_names:, columns: {},
                                     indexes: {})
      end
      expect(ddl("parallel_hash_join", stats: enclave::Statistics.new(tables:))).to eq([btree("visits", "event_id")])
    end

    it "counts a plain Hash under a Gather once, since each worker builds a whole copy" do
      # Each of three participants hashes all 40,000 rows, in one batch.
      tables = { "events" => %w[id kind], "visits" => %w[id event_id] }.map do |name, column_names|
        enclave::TableStatistics.new(name: table_name(name), reltuples: 1, column_names:, columns: {}, indexes: {})
      end
      stats = enclave::Statistics.new(tables:)
      expect(ddl("gather_hash_join", stats:, large_hash_rows: 40_001)).to eq([])
      expect(ddl("gather_hash_join", stats:, large_hash_rows: 40_000)).to eq([btree("visits", "event_id")])
    end
  end

  describe "a BitmapOr or BitmapAnd of single-column indexes" do
    it "proposes one composite index on their columns, each column once" do
      # BitmapOr of customers_pkey, customers_email_key, and customers_pkey.
      expect(ddl("bitmap_or")).to eq([btree("customers", "id, email")])
      expect(ddl("bitmap_and")).to eq([btree("orders", "customer_id, id")])
      # BitmapOr of a BitmapAnd (orders_customer_id_idx, orders_pkey) and orders_pkey.
      expect(ddl("bitmap_and_in_or")).to eq([btree("orders", "customer_id, id")])
    end

    it "leaves out an index with more than one column, and needs two columns left" do
      two_columns = customers_stats.with(
        indexes: customers_stats.indexes.merge(
          indexes("public", "customers_email_key" =>
                              "CREATE UNIQUE INDEX customers_email_key ON public.customers USING btree (email, name)")
        )
      )
      stats = enclave::Statistics.new(tables: [orders_stats, two_columns])
      expect(ddl("bitmap_or", stats:)).to eq([])
    end
  end

  describe "a plain EXPLAIN plan, as a rewrite has on the racetrack (analyzed: false)" do
    # Strip everything only ANALYZE prints, recursively.
    def plain(value)
      case value
      when Array then value.map { |v| plain(v) }
      when Hash
        value.reject { |k, _| k.start_with?("Actual ", "Rows Removed", "Hash Batches", "Original Hash Batches") }
             .transform_values { |v| plain(v) }
      else value
      end
    end

    def plain_ddl(name) = described_class.candidates(plain(plan(name)), statistics:, analyzed: false).map(&:to_ddl)

    it "runs the patterns that need neither actual rows nor rows removed" do
      expect(plain_ddl("sort_under_limit")).to eq([btree("orders", "customer_id, created_at DESC")])
      expect(plain_ddl("bitmap_or")).to eq([btree("customers", "id, email")])
      expect(plain_ddl("hash_aggregate")).to eq([btree("orders", "status, total_cents")])
    end

    it "skips the patterns that need actual rows or rows removed" do
      %w[seq_scan_most_rows index_scan_filter nested_loop_inner hash_join_batches].each do |name|
        expect(ddl(name)).not_to be_empty
        expect(plain_ddl(name)).to eq([]), name
      end
    end

    it "skips them even on a plan that has actual rows" do
      expect(described_class.candidates(plan("seq_scan_most_rows"), statistics:, analyzed: false)).to eq([])
    end
  end

  describe "an aggregate" do
    it "indexes the GROUP BY keys of a hash aggregate" do
      expect(ddl("hash_aggregate")).to eq([btree("orders", "status, total_cents")])
    end

    it "proposes one index for each table in the GROUP BY" do
      expect(ddl("hash_aggregate_two_tables")).to eq([btree("customers", "name"), btree("orders", "status")])
    end

    it "indexes a sorted aggregate's GROUP BY keys beyond what its Sort proposes" do
      # GroupAggregate over Sort, Group Key and Sort Key both c.name, o.status.
      # The Sort pattern stops at o.status. The aggregate doesn't.
      expect(ddl("group_aggregate_two_tables")).to eq([btree("customers", "name"), btree("orders", "status")])
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
        [btree("orders", "total_cents, status"), btree("orders", "status, created_at", " WHERE total_cents = 5100")]
      )
      expect(ddl("seq_scan_most_rows", stats:)).to eq([])
    end

    it "skips a relation with no statistics" do
      expect(ddl("init_plan", stats: enclave::Statistics.new(tables: [customers_stats]))).to eq([])
    end

    it "uses the one table with the name, even when schemas doesn't list its schema" do
      expect(ddl("init_plan", schemas: ["archive"])).to eq([btree("orders", "total_cents")])
    end
  end

  describe "its output" do
    it "is a frozen array, the same on every call" do
      first = generate("nested_loop_inner")
      expect(first).to be_frozen
      expect(generate("nested_loop_inner")).to eq(first)
    end
  end

  describe "its thresholds" do
    it "default to the values the task decided" do
      expect(described_class::THRESHOLDS).to eq(
        most_rows_removed: 0.9, many_rows_removed: 0.5, many_rows_min: 1000,
        expensive_inner_rows: 10_000, large_hash_rows: 100_000, large_hash_batches: 2
      )
    end
  end

  describe "bad input" do
    it "refuses anything but the parsed EXPLAIN JSON array" do
      [{ "Plan" => {} }, [], [{ "Plan" => "x" }], [{}], nil].each do |bad|
        expect { described_class.candidates(bad, statistics:) }.to raise_error(ArgumentError, /EXPLAIN/), bad.inspect
      end
    end

    it "refuses a count that isn't a number, without quoting it" do
      ["Actual Rows", "Actual Loops", "Rows Removed by Filter", "Rows Removed by Index Recheck"].each do |field|
        explain = plan("sentinel_literals")
        explain.first["Plan"][field] = ["quaack-sentinel-email"]
        expect { described_class.candidates(explain, statistics:) }
          .to raise_error(ArgumentError, /isn't a number/) { |e| expect(e.message).not_to include("quaack-sentinel") }
      end
      explain = plan("hash_join_batches")
      explain.first["Plan"]["Plans"][1]["Hash Batches"] = "quaack-sentinel-email"
      expect { described_class.candidates(explain, statistics:) }
        .to raise_error(ArgumentError, /isn't a number/) { |e| expect(e.message).not_to include("quaack-sentinel") }
    end

    it "refuses a plan made without ANALYZE" do
      explain = plan("seq_scan_rare_value")
      explain.first["Plan"].delete("Actual Loops")
      expect { described_class.candidates(explain, statistics:) }.to raise_error(ArgumentError, /ANALYZE/)
    end

    it "refuses a plan node that isn't an object" do
      expect { described_class.candidates([{ "Plan" => { "Actual Loops" => 1, "Plans" => ["x"] } }], statistics:) }
        .to raise_error(ArgumentError, /plan node/)
    end

    it "refuses a threshold it doesn't know" do
      expect { generate("init_plan", most_rows: 0.5) }.to raise_error(ArgumentError, /unknown thresholds: most_rows/)
    end

    it "refuses statistics that aren't a Statistics, and schemas that aren't names" do
      expect { described_class.candidates(plan("init_plan"), statistics: {}) }
        .to raise_error(ArgumentError, /Statistics/)
      [" public", ["public", :archive]].each do |bad|
        expect { described_class.candidates(plan("init_plan"), statistics:, schemas: bad) }
          .to raise_error(ArgumentError, /schemas/), bad.inspect
      end
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

    it "come from equally selective columns, which keep the plan's order" do
      # email and name both have an equality selectivity of 1/2,000.
      expect(generate("sentinel_literals").first.to_ddl).to eq(btree("customers", "email, name"))
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

    it "never show up in pp, to_h, or a failed pattern match on those helpers" do
      node = enclave.const_get(:PlanNode).new(plan("sentinel_literals").first["Plan"])
      columns = enclave.const_get(:PlanColumns).new(node.subtree, statistics, nil)
      conjunct = columns.conjuncts(node, ["Filter"], "c").first
      expect(enclave.const_get(:PlanExpression).literal_text(conjunct.node)).to eq("quaack-sentinel-email")
      shown = [node, columns, conjunct].map(&:pretty_inspect).join
      shown += conjunct.to_h.inspect if conjunct.respond_to?(:to_h)
      shown += begin
        case conjunct
        in { node: } then node.inspect
        end
      rescue NoMatchingPatternError => e
        e.message
      end
      sentinels.each { |s| expect(shown).not_to include(s) }
    end

    it "never show up in an error message" do
      explain = plan("sentinel_literals")
      explain.first["Plan"]["Plans"] = "not a list, #{sentinels.first}"
      child = plan("sentinel_literals")
      child.first["Plan"]["Plans"] = [child.first["Plan"]["Filter"]]
      bad_inputs = [explain, child, [plan("sentinel_literals").first.to_a], plan("sentinel_literals").first]
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
      expect(expression.sort_key("total_cents NULLS FIRST").drop(1)).to eq(%i[asc first])
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

    it "reads a decimal literal as its text" do
      expect(expression.literal_text(expression.conjuncts("(x = 1.50)").first)).to eq("1.50")
    end

    it "reads a boolean literal as its text" do
      expect(expression.literal_text(expression.conjuncts("(x = false)").first)).to eq("false")
    end

    it "reads a cast literal on either side, and nothing for NULL, a parameter, or a column" do
      text = ->(sql) { expression.literal_text(expression.conjuncts(sql).first) }
      expect(text.call("('-5'::integer = x)")).to eq("-5")
      expect(text.call("(x = NULL::text)")).to be_nil
      expect(text.call("(x = $1)")).to be_nil
      expect(text.call("(x = y)")).to be_nil
      expect(text.call("(x < 5)")).to be_nil
    end

    it "drops every qualifier from a predicate, keeping its casts" do
      node = expression.conjuncts("(s.o.status = 'x'::text)").first
      expect(expression.unqualified_sql(node)).to eq("status = 'x'::text")
    end

    # pg_query writes 't'::boolean as true, so the predicate would parse as
    # another tree. The error has no text of the plan's.
    it "raises, quoting nothing, rather than give a predicate that means something else" do
      node = expression.conjuncts("((o.a = 'quaack-sentinel') IS NOT DISTINCT FROM 't'::boolean)").first
      expect { expression.unqualified_sql(node) }.to raise_error(enclave::Deparse::Error) { |e|
        expect([e.rule, e.cause]).to eq(["deparse_mismatch", nil])
        expect(e.full_message).not_to include("quaack-sentinel")
      }
    end

    it "sorts conditions into constant equalities, join equalities, and the rest" do
      scans = enclave.const_get(:PlanNode).new(plan("hash_join_batches").first["Plan"]).subtree
      columns = enclave.const_get(:PlanColumns).new(scans, statistics, nil)
      kinds = lambda do |filter|
        node = enclave.const_get(:PlanNode).new("Filter" => filter)
        columns.conjuncts(node, ["Filter"], "o").map { |c| [c.kind, c.columns.map(&:name)] }
      end
      expect(kinds.call("((status)::varchar = 'x'::text)")).to eq([[:constant, ["status"]]])
      expect(kinds.call("(o.customer_id = c.id)")).to eq([[:join, %w[customer_id id]]])
      expect(kinds.call("(total_cents = customer_id)")).to eq([[:other, %w[total_cents customer_id]]])
      expect(kinds.call("(status = ANY ('{a,b}'::text[]))")).to eq([[:other, ["status"]]])
      expect(kinds.call("(o.status.x = 'x'::text)")).to eq([[:other, []]])
      # A column of an alias the plan has no scan for isn't a constant.
      expect(kinds.call("(total_cents = z.id)")).to eq([[:other, ["total_cents"]]])
    end

    it "reads a bare key as the plan's one alias, and only when there's one" do
      one = enclave.const_get(:PlanNode).new(plan("seq_scan_parameter").first["Plan"]).subtree
      two = enclave.const_get(:PlanNode).new(plan("hash_join_batches").first["Plan"]).subtree
      keys = ->(nodes) { enclave.const_get(:PlanColumns).new(nodes, statistics, nil).sort_keys(["id"]) }
      expect(keys.call(one).map { |column, *| [column.alias_name, column.name] }).to eq([%w[o id]])
      expect(keys.call(two)).to eq([])
    end
  end
end
