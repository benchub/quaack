# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare's check of arbitrary picks (task 20261008-67): a DISTINCT
# ON without an ORDER BY that fixes the kept row, an aggregate whose value
# follows its input order (any_value, array_agg and the like), and a
# DISTINCT or a set operation that drops duplicates, which keeps one of
# several values Postgres calls equal. Each query runs again with its picks
# forced one way and then the other, and the original's answer must not
# depend on them, nor may the candidate's give a wrong one.
RSpec.describe Quaack::Enclave::ResultComparison do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE items (id integer PRIMARY KEY, grp integer NOT NULL, label text, jb jsonb)
    SQL
  end

  # grp 1 ties three ways, with labels in id order. Six rows or fewer, so a
  # sort keeps its input order for ties.
  let(:fixture) do
    [[1, 1, "a"], [2, 1, "b"], [3, 1, "c"], [4, 2, "d"]].map do |id, grp, label|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp label],
                                                   values: [id.to_s, grp.to_s, label])
    end
  end

  # Two jsonb values Postgres calls equal that print differently.
  let(:equal_jsonb) do
    [[1, 1, '{"a": 1.0}'], [2, 2, '{"a": 1.00}']].map do |id, grp, jb|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp jb],
                                                   values: [id.to_s, grp.to_s, jb])
    end
  end

  def compare(original, candidate, rows: fixture)
    runner.with_fixture(rows) { |tx| described_class.compare(tx, original:, candidate:) }
  end

  def in_load_orders(original, candidate, rows: fixture)
    described_class.compare_in_load_orders(runner, rows, original:, candidate:)
  end

  def raw(*queries, rows: fixture)
    runner.with_fixture(rows) { |tx| queries.map { |sql| tx.query(sql).rows } }
  end

  def fields(verdict) = verdict.to_h.slice(:match, :rule)

  def subquery(inner) = "SELECT grp, label FROM (#{inner}) s"
  def cte(inner) = "WITH s AS (#{inner}) SELECT grp, label FROM s"

  describe "DISTINCT ON without an ORDER BY that fixes the kept row" do
    let(:keyed) { "SELECT DISTINCT ON (grp) grp, label FROM items ORDER BY grp, label" }
    let(:loose) { "SELECT DISTINCT ON (grp) grp, label FROM items ORDER BY grp" }

    it "is a mismatch for a candidate that drops the key that picks the row, in a subquery and a CTE" do
      [method(:subquery), method(:cte)].each do |form|
        # Loaded forward, the loose sort keeps id 1, the row the keyed one keeps.
        expect(raw(form.call(keyed), form.call(loose)).map(&:sort)).to eq([[%w[1 a], %w[2 d]]] * 2)

        expect(fields(compare(form.call(keyed), form.call(loose)))).to eq(match: false, rule: :multiset)
      end
    end

    it "refuses when the original's own pick decides its answer, not failing a candidate that picks another row" do
      original = subquery(loose)
      candidate = subquery("SELECT DISTINCT ON (grp) grp, label FROM items ORDER BY grp, id DESC")

      expect(fields(compare(original, candidate))).to eq(match: false, rule: :unsupported_order)
      expect(fields(in_load_orders(original, candidate))).to eq(match: false, rule: :unsupported_order)
    end

    it "matches when the original's pick doesn't matter on the data" do
      rows = fixture.values_at(0, 3)

      expect(compare(subquery(keyed), subquery(loose), rows:).match?).to be(true)
      expect(compare(subquery(loose), subquery(keyed), rows:).match?).to be(true)
    end

    it "is a mismatch for a LATERAL subquery that drops the key, where the pick reads the outer row" do
      lateral = "SELECT g.grp, l.label FROM (VALUES (1), (2)) g (grp) CROSS JOIN LATERAL " \
                "(SELECT DISTINCT ON (grp) label FROM items WHERE items.grp = g.grp ORDER BY grp%s) l"
      expect(raw(format(lateral, ", label"), format(lateral, "")).map(&:sort)).to eq([[%w[1 a], %w[2 d]]] * 2)

      expect(fields(compare(format(lateral, ", label"), format(lateral, "")))).to eq(match: false, rule: :multiset)
    end

    it "matches a DISTINCT ON whose ORDER BY fixes the kept row" do
      candidate = subquery("SELECT DISTINCT ON (grp) grp, label FROM items ORDER BY grp, label, id")

      expect(compare(subquery(keyed), candidate).match?).to be(true)
    end
  end

  describe "DISTINCT ON over *" do
    it "sorts the ties by each relation's whole row, named by its alias or its schema" do
      keyed = "SELECT grp, label FROM (SELECT DISTINCT ON (i.grp) * FROM public.items i ORDER BY i.grp, i.id) s"
      loose = ["SELECT grp, label FROM (SELECT DISTINCT ON (grp) * FROM public.items ORDER BY grp) s",
               "SELECT grp, label FROM (SELECT DISTINCT ON (i.grp) i.* FROM items i ORDER BY i.grp) s",
               "SELECT grp, label FROM (SELECT DISTINCT ON (i.grp) * FROM items i " \
               "JOIN (SELECT id AS jid FROM items) j ON j.jid = i.id ORDER BY i.grp) s",
               "SELECT grp, label FROM (SELECT DISTINCT ON (grp) * FROM (SELECT 1 AS k) o " \
               "CROSS JOIN items ORDER BY grp) s",
               "SELECT grp, label FROM (SELECT DISTINCT ON (grp) * FROM other.items " \
               "CROSS JOIN public.items ORDER BY grp) s"]
      conn.exec("CREATE SCHEMA other; CREATE TABLE other.items (k integer); INSERT INTO other.items VALUES (1)")

      loose.each do |candidate|
        expect(raw(keyed, candidate).map(&:sort)).to eq([[%w[1 a], %w[2 d]]] * 2)
        expect(fields(compare(keyed, candidate))).to eq(match: false, rule: :multiset)
      end
    end

    it "refuses a * over a FROM item with no name" do
      sql = "SELECT grp, label FROM (SELECT DISTINCT ON (grp) * FROM (SELECT grp, label FROM items)) s"

      expect(fields(compare(sql, sql))).to eq(match: false, rule: :unsupported_order)
    end
  end

  describe "an aggregate whose value follows its input order" do
    def grouped(aggregate) = "SELECT grp, #{aggregate} AS label FROM items GROUP BY grp"

    it "is a mismatch for an any_value that stands in for min, in a subquery, a CTE, and at the top level" do
      [method(:subquery), method(:cte), ->(sql) { sql }].each do |form|
        original = form.call(grouped("min(label)"))
        candidate = form.call(grouped("any_value(label)"))
        expect(raw(original, candidate).map(&:sort)).to eq([[%w[1 a], %w[2 d]]] * 2)

        expect(fields(compare(original, candidate))).to eq(match: false, rule: :multiset)
      end
    end

    it "is a mismatch for an array_agg or string_agg that drops its ORDER BY" do
      {
        "array_agg(label ORDER BY label)::text" => "array_agg(label)::text",
        "string_agg(label, ',' ORDER BY id)" => "string_agg(label, ',')",
        "string_agg(label, ',' ORDER BY grp, label)" => "string_agg(label, ',' ORDER BY grp)"
      }.each do |keyed, loose|
        original = subquery(grouped(keyed))
        candidate = subquery(grouped(loose))
        first, second = raw(original, candidate)
        expect(second.sort).to eq(first.sort)

        expect(fields(compare(original, candidate))).to eq(match: false, rule: :multiset)
      end
    end

    it "refuses when the original's own aggregate's pick decides its answer" do
      original = subquery(grouped("any_value(label)"))
      candidate = subquery(grouped("min(label)"))

      expect(fields(compare(original, candidate))).to eq(match: false, rule: :unsupported_order)
      expect(fields(in_load_orders(original, candidate))).to eq(match: false, rule: :unsupported_order)
    end

    it "matches when no group holds two values, and leaves DISTINCT and window aggregates alone" do
      rows = fixture.values_at(0, 3)
      expect(compare(subquery(grouped("min(label)")), subquery(grouped("any_value(label)")), rows:).match?).to be(true)

      distinct = subquery(grouped("array_agg(DISTINCT label)::text"))
      window = "SELECT grp, label FROM (SELECT grp, (array_agg(label) OVER (PARTITION BY grp))::text AS label " \
               "FROM items) s"
      expect(compare(distinct, distinct).match?).to be(true)
      expect(compare(window, window).match?).to be(true)
    end
  end

  describe "a DISTINCT or set operation that keeps one of several equal values" do
    def texts(inner) = "SELECT jb::text FROM (#{inner}) s"

    it "refuses an original whose DISTINCT or UNION keeps either of two equal jsonb values" do
      [texts("SELECT DISTINCT jb FROM items"),
       texts("SELECT jb FROM items WHERE grp = 1 UNION SELECT jb FROM items WHERE grp = 2"),
       "WITH s AS (SELECT DISTINCT jb FROM items) SELECT jb::text FROM s",
       "SELECT DISTINCT jb FROM items"].each do |sql|
        expect(raw(sql, rows: equal_jsonb)).to eq([[['{"a": 1.0}']]])

        expect(fields(compare(sql, sql, rows: equal_jsonb))).to eq(match: false, rule: :unsupported_order)
      end
    end

    it "is a mismatch for a candidate whose DISTINCT, UNION, INTERSECT, or EXCEPT can keep another value" do
      original = texts("SELECT jb FROM items WHERE id = 1")
      one_group = equal_jsonb.map { |row| row.with(values: [row.values[0], "1", row.values[2]]) }
      {
        "SELECT DISTINCT jb FROM items" => equal_jsonb,
        "SELECT jb FROM items WHERE grp = 1 UNION SELECT jb FROM items WHERE grp = 2" => equal_jsonb,
        "SELECT jb FROM items WHERE grp = 1 EXCEPT SELECT '{}'::jsonb" => one_group,
        "SELECT jb FROM items INTERSECT SELECT jb FROM items" => equal_jsonb
      }.each do |inner, rows|
        expect(raw(original, texts(inner), rows:)).to eq([[['{"a": 1.0}']]] * 2)

        expect(fields(compare(original, texts(inner), rows:))).to eq(match: false, rule: :multiset)
      end
    end

    it "leaves a DISTINCT at an ordered top level to the tiebreaker, which keeps its order" do
      sql = "SELECT DISTINCT grp FROM items ORDER BY grp DESC"

      expect(compare(sql, sql).match?).to be(true)
    end

    it "matches when the equal values print the same" do
      rows = equal_jsonb.map { it.with(values: [*it.values[0, 2], '{"a": 1}']) }
      original = texts("SELECT jb FROM items WHERE id = 1")
      candidate = texts("SELECT jb FROM items WHERE grp = 1 UNION SELECT jb FROM items WHERE grp = 2")

      expect(compare(candidate, candidate, rows:).match?).to be(true)
      expect(compare(original, candidate, rows:).match?).to be(true)
    end
  end
end
