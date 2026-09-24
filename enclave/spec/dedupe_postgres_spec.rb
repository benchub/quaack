# frozen_string_literal: true

require "json"
require "quaack/enclave/dedupe"

# Checks Dedupe.covers? against the planner. For each case, a real index
# stands for the existing index, read back through pg_get_indexdef and
# IndexCandidate.from_ddl, as README 3b will read it. The candidate is
# created with HypoPG, as 5a-4 would. The query is one the candidate
# serves on its own: the planner scans the candidate, with no sort, no
# filter on the scan, and an index-only scan when the candidate has INCLUDE
# columns. The existing index covers the candidate when it serves that query
# the same way, with the candidate's index gone.
RSpec.describe "Dedupe.covers? against the planner" do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "t") }

  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS hypopg;
      CREATE TABLE t (a int, b int, c int, d int, s text);
      INSERT INTO t SELECT i % 1000, i % 7, i, i * 2, md5(i::text) FROM generate_series(1, 100000) AS i;
    SQL
    conn.exec("VACUUM ANALYZE t")
  end

  def plan_nodes(query)
    conn.exec("SET enable_seqscan = off; SET enable_bitmapscan = off")
    root = JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) #{query}").getvalue(0, 0)).first["Plan"]
    walk = ->(node) { [node, *(node["Plans"] || []).flat_map(&walk)] }
    walk[root]
  end

  # Whether the index named index_name serves the query the way the case
  # asks: it's scanned, and there's no Sort and no Filter anywhere in the
  # plan, and it's an index-only scan when index_only is set.
  def serves?(query, index_name, index_only:)
    nodes = plan_nodes(query)
    scan = nodes.find { |n| n["Index Name"] == index_name }
    return false unless scan
    return false if nodes.any? { |n| n["Node Type"].include?("Sort") || n.key?("Filter") }

    !index_only || scan["Node Type"] == "Index Only Scan"
  end

  def candidate_serves?(candidate, query)
    name = conn.exec_params("SELECT indexname FROM hypopg_create_index($1)", [candidate.to_ddl]).getvalue(0, 0)
    serves?(query, name, index_only: candidate.include.any?)
  ensure
    conn.exec("SELECT hypopg_reset()")
  end

  def existing_index(definition, unique:)
    conn.exec("CREATE #{"UNIQUE " if unique}INDEX existing_idx ON t #{definition}")
    ddl = conn.exec("SELECT pg_get_indexdef('existing_idx'::regclass)").getvalue(0, 0)
    Quaack::Enclave::IndexCandidate.from_ddl(ddl, sources: [:existing])
  end

  def candidate(**)
    Quaack::Enclave::IndexCandidate.new(table: t, sources: [:parse], **)
  end

  def key(name, direction, nulls = nil) = Quaack::Enclave::IndexCandidate::KeyColumn.new(name:, direction:, nulls:)

  # existing is the real index's definition after ON t. covered is what
  # Dedupe.covers? must say. It matches whether the planner serves the
  # query with the existing index, except where exception says why not.
  cases = [
    { name: "a leading prefix", existing: "(a, b, d)", candidate: { key: ["a"] },
      query: "SELECT * FROM t WHERE a = 5", covered: true },
    { name: "a prefix read backward", existing: "(a, b, d)",
      candidate: { key: [%w[a desc], %w[b desc]] },
      query: "SELECT * FROM t ORDER BY a DESC, b DESC LIMIT 10", covered: true },
    { name: "mixed directions", existing: "(a, b)", candidate: { key: ["a", %w[b desc]] },
      query: "SELECT * FROM t ORDER BY a, b DESC LIMIT 10", covered: false },
    { name: "a different nulls ordering", existing: "(a)", candidate: { key: [%w[a asc first]] },
      query: "SELECT * FROM t ORDER BY a NULLS FIRST LIMIT 10", covered: false },
    { name: "nulls ordering flipped with the direction", existing: "(a NULLS FIRST)",
      candidate: { key: [%w[a desc last]] },
      query: "SELECT * FROM t ORDER BY a DESC NULLS LAST LIMIT 10", covered: true },
    { name: "a btree candidate under a BRIN", existing: "USING brin (a)", candidate: { key: ["a"] },
      query: "SELECT * FROM t ORDER BY a LIMIT 10", covered: false },
    { name: "a btree candidate under a hash", existing: "USING hash (a)", candidate: { key: ["a"] },
      query: "SELECT * FROM t ORDER BY a LIMIT 10", covered: false },
    { name: "a BRIN candidate under a btree", existing: "(c)", candidate: { key: ["c"], access_method: :brin },
      query: "SELECT * FROM t WHERE c BETWEEN 100 AND 200", covered: false,
      exception: "the btree serves it, but a BRIN is worth testing for its size" },
    { name: "a BRIN candidate under a multicolumn BRIN", existing: "USING brin (c, d)",
      candidate: { key: ["c"], access_method: :brin },
      query: "SELECT * FROM t WHERE c BETWEEN 100 AND 200", covered: false,
      exception: "the wider BRIN serves it, but only an exact match covers a method other than btree" },
    { name: "a plain candidate under a partial index", existing: "(a) WHERE b = 1", candidate: { key: ["a"] },
      query: "SELECT * FROM t WHERE a = 5", covered: false },
    { name: "a partial candidate under a plain index", existing: "(a)",
      candidate: { key: ["a"], predicate: "b = 1" },
      query: "SELECT * FROM t WHERE a = 5 AND b = 1", covered: false },
    { name: "a partial candidate under the same predicate", existing: "(a, d) WHERE b = 1",
      candidate: { key: ["a"], predicate: "b = 1" },
      query: "SELECT * FROM t WHERE a = 5 AND b = 1", covered: true },
    { name: "a prefix of a unique index", existing: "(c, a)", unique: true, candidate: { key: ["c"] },
      query: "SELECT * FROM t WHERE c = 5", covered: true },
    { name: "an INCLUDE column in the existing key", existing: "(a, b)",
      candidate: { key: ["a"], include: ["b"] },
      query: "SELECT a, b FROM t WHERE a = 5", covered: true },
    { name: "INCLUDE columns in another order", existing: "(a) INCLUDE (d, b)",
      candidate: { key: ["a"], include: %w[b d] },
      query: "SELECT a, b, d FROM t WHERE a = 5", covered: true },
    { name: "an INCLUDE column the existing index lacks", existing: "(a, b)",
      candidate: { key: ["a"], include: ["d"] },
      query: "SELECT a, d FROM t WHERE a = 5", covered: false },
    { name: "a key column the existing index only INCLUDEs", existing: "(a) INCLUDE (b)",
      candidate: { key: %w[a b] },
      query: "SELECT * FROM t WHERE a = 5 ORDER BY b LIMIT 10", covered: false },
    { name: "an existing index with an opclass", existing: "(s text_pattern_ops)", candidate: { key: ["s"] },
      query: "SELECT * FROM t ORDER BY s LIMIT 10", covered: false },
    { name: "an existing index with a collation", existing: "(s COLLATE \"C\")", candidate: { key: ["s"] },
      query: "SELECT * FROM t ORDER BY s LIMIT 10", covered: false }
  ].freeze

  cases.each do |c|
    it "#{c[:covered] ? "covers" : "doesn't cover"} #{c[:name]}" do
      cand = candidate(**c[:candidate], key: c[:candidate][:key].map { |k| k.is_a?(Array) ? key(*k) : k })
      expect(candidate_serves?(cand, c[:query])).to be(true), "the candidate itself doesn't serve the query"

      index = existing_index(c[:existing], unique: c.fetch(:unique, false))
      planner_says = serves?(c[:query], "existing_idx", index_only: cand.include.any?)
      expect(planner_says).to be(c.key?(:exception) ? !c[:covered] : c[:covered]), "the planner disagrees"

      expect(!index.nil? && Quaack::Enclave::Dedupe.covers?(index, cand)).to be(c[:covered])
    end
  end
end
