# frozen_string_literal: true

require "json"
require "quaack/enclave/statistics"
require "quaack/enclave/pg_array"

# Checks value_frequency against the planner itself: statistics read from a
# real pg_stats, times reltuples, should give the row count EXPLAIN
# estimates for `column = literal`.
RSpec.describe "value_frequency against real Postgres statistics" do
  let(:conn) { test_database.connection }

  def pg_stats_row(table, column)
    conn.exec_params(<<~SQL, [table, column]).first
      SELECT n_distinct, null_frac, correlation, most_common_vals::text AS vals, most_common_freqs::text AS freqs
      FROM pg_stats WHERE schemaname = 'public' AND tablename = $1 AND attname = $2
    SQL
  end

  def column_statistics(table, column)
    row = pg_stats_row(table, column)
    number = ->(text) { text && Float(text) }
    array = ->(text) { text && Quaack::Enclave::PgArray.parse(text) }
    Quaack::Enclave::ColumnStatistics.new(
      **%w[n_distinct null_frac correlation].to_h { |key| [key.to_sym, number[row[key]]] },
      most_common_vals: array[row["vals"]], most_common_freqs: array[row["freqs"]]&.map(&number)
    )
  end

  def table_statistics(table, column)
    reltuples = conn.exec_params("SELECT reltuples FROM pg_class WHERE oid = $1::regclass", [table]).getvalue(0, 0)
    Quaack::Enclave::TableStatistics.new(
      name: Quaack::Enclave::TableName.new(schema: "public", name: table), reltuples: Float(reltuples),
      columns: { column => column_statistics(table, column) }, column_names: [column], indexes: {}
    )
  end

  def planner_rows(table, column, literal)
    plan = conn.exec("EXPLAIN (FORMAT JSON) SELECT * FROM #{table} WHERE #{column} = #{conn.escape_literal(literal)}")
    JSON.parse(plan.getvalue(0, 0)).dig(0, "Plan", "Plan Rows")
  end

  # The planner rounds its row estimate and never goes below one row.
  def our_rows(stats, column, literal)
    [stats.value_frequency(column, literal) * stats.reltuples, 1.0].max
  end

  it "matches the planner on orders.status, for an MCV and for a value that isn't one" do
    stats = table_statistics("orders", "status")

    expect(stats.column("status").most_common_vals).to include("shipped")
    expect(stats.column("status").most_common_vals).not_to include("lost")
    %w[shipped lost].each do |literal|
      expect(our_rows(stats, "status", literal)).to be_within(1).of(planner_rows("orders", "status", literal)), literal
    end
  end

  # Every orders.status value is an MCV, so the one above that isn't comes
  # out at the one-row floor. This table's MCV list covers only some of its
  # values, and it has nulls, so the estimate for the rest is well above
  # the floor.
  it "matches the planner on a column whose MCV list leaves out most of its values" do
    conn.exec(<<~SQL)
      CREATE TABLE skewed (v text);
      INSERT INTO skewed SELECT 'hot' FROM generate_series(1, 5000);
      INSERT INTO skewed SELECT 'warm' FROM generate_series(1, 1000);
      INSERT INTO skewed SELECT 'cold-' || i % 500 FROM generate_series(1, 4000) AS i;
      INSERT INTO skewed SELECT NULL FROM generate_series(1, 1000);
      ANALYZE skewed;
    SQL
    stats = table_statistics("skewed", "v")
    column = stats.column("v")

    expect(column.most_common_vals).to include("hot", "warm")
    expect(column.most_common_vals).not_to include("cold-7")
    expect(column.null_frac).to be_positive
    expect(our_rows(stats, "v", "cold-7")).to be > 5
    %w[hot warm cold-7].each do |literal|
      expect(our_rows(stats, "v", literal)).to be_within(1).of(planner_rows("skewed", "v", literal)), literal
    end
  end
end
