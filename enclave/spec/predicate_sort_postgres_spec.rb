# frozen_string_literal: true

require "quaack/enclave/index_candidate"

# Task 20261009-17: sorting a predicate's operands doesn't change what Postgres
# plans, against a real server.
RSpec.describe "predicate operand order, against a real server" do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "sort_t") }

  def sorted(sql)
    Quaack::Enclave::IndexCandidate.new(table: t, key: ["a"], sources: [:parse], predicate: sql).predicate
  end

  def plan(where)
    conn.exec("EXPLAIN (COSTS OFF) SELECT a FROM sort_t WHERE #{where}").map { it["QUERY PLAN"] }
  end

  it "plans the same with sorted and unsorted predicates" do
    conn.exec("CREATE TABLE sort_t (a int, b text, c text, d boolean)")
    conn.exec("INSERT INTO sort_t SELECT i, 'b', 'c', i % 2 = 0 FROM generate_series(1, 2000) i")
    conn.exec("CREATE INDEX ON sort_t (a) WHERE b = 'b' AND c <> 'x' AND (d IS NULL OR NOT d)")
    conn.exec("ANALYZE sort_t")
    written = "(d IS NULL OR NOT d) AND c <> 'x' AND b = 'b' AND a = 7"
    reordered = sorted(written)
    expect(reordered).not_to eq(written)
    expect(plan(reordered)).to eq(plan(written))
    expect(plan(written).join).to include("Index")
  end

  # Task 20261009-19: the real index-dedupe path.
  it "covers a candidate whose predicate is an existing index's, reordered" do
    require "quaack/enclave/dedupe"
    conn.exec("CREATE TABLE sort_t (a int, b int, c int, d boolean)")
    conn.exec("CREATE INDEX sort_idx ON sort_t (a) WHERE b = 2 AND c <> 3 AND (d IS NULL OR NOT d)")
    ddl = conn.exec("SELECT pg_get_indexdef('sort_idx'::regclass)").getvalue(0, 0)
    existing = Quaack::Enclave::IndexCandidate.from_indexdef(ddl)
    candidate = lambda do |predicate|
      Quaack::Enclave::IndexCandidate.new(table: t, key: ["a"], sources: [:parse], predicate:)
    end
    reordered = candidate.call("(NOT d OR d IS NULL) AND c <> 3 AND b = 2")
    expect(Quaack::Enclave::Dedupe.covers?(existing, reordered)).to be(true)
    other = candidate.call("c <> 3 AND b = 2")
    expect(Quaack::Enclave::Dedupe.covers?(existing, other)).to be(false)
  end
end
