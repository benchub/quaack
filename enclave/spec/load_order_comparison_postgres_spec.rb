# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# Step 9d runs each comparison twice: with the fixture loaded forward, and
# again loaded in reverse. A rewrite that drops a sort key below the top
# level, or keeps a different representative of equal values, matches the
# forward load only because the rows went in in that order.
RSpec.describe Quaack::Enclave::ResultComparison, ".compare_in_both_orders" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  def table(name) = Quaack::Enclave::TableName.new(schema: "public", name:)

  def rows_of(name, columns, *rows)
    rows.map do |values|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: table(name), columns:, values: values.map { |v| v&.to_s })
    end
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE items (id integer PRIMARY KEY, grp integer NOT NULL, label text, iv interval);
      CREATE TABLE parent (id integer PRIMARY KEY);
      CREATE TABLE child (id integer PRIMARY KEY, parent_id integer REFERENCES parent);
    SQL
  end

  # Loaded in id order, the way a scenario is. grp 1 ties three ways, and
  # within it label ties twice. The two intervals in grp 1 are equal to
  # Postgres but print differently.
  let(:items) do
    rows_of("items", %w[id grp label iv],
            [1, 1, "x", "1 day"], [2, 1, "x", "24 hours"], [3, 1, "y", "1 day"],
            [4, 2, "x", "1 day"], [5, 2, "x", "1 day"])
  end

  def both(original, candidate, rows: items, inserts: [])
    described_class.compare_in_both_orders(runner, rows, inserts:, original:, candidate:)
  end

  # The comparison as it was before, with only the forward load.
  def forward_only(original, candidate, rows: items)
    runner.with_fixture(rows) { |tx| described_class.compare(tx, original:, candidate:) }
  end

  def fields(verdict) = verdict.to_h.slice(:match, :mode, :rule, :load_order)

  describe "the reverse load" do
    let(:scan_order) { "SELECT string_agg(id::text, ',') FROM items" }

    it "loads the rows in reverse, so a seq scan returns them in reverse" do
      scans = [items, described_class.reverse_load(items)].map do |rows|
        runner.with_fixture(rows) { |tx| tx.query(scan_order).rows }
      end
      expect(scans).to eq([[["1,2,3,4,5"]], [["5,4,3,2,1"]]])

      verdict = both(scan_order, "SELECT '1,2,3,4,5'")

      expect(fields(verdict)).to eq(match: false, mode: :multiset, rule: :multiset, load_order: :reverse)
    end

    it "runs the forward load first, and says so when it disproves the candidate" do
      verdict = both(scan_order, "SELECT '5,4,3,2,1'")

      expect(fields(verdict)).to eq(match: false, mode: :multiset, rule: :multiset, load_order: :forward)
    end

    it "keeps nothing between the two runs, or after them" do
      verdict = both("SELECT count(*) FROM items", "SELECT 5::int8")

      expect(fields(verdict)).to eq(match: true, mode: :multiset, rule: nil, load_order: nil)
      expect(conn.exec("SELECT count(*) FROM items").getvalue(0, 0)).to eq("0")
    end
  end

  describe "rewrites that match the forward load only by luck" do
    it "catches a subquery that drops its secondary sort key before a LIMIT" do
      original = "SELECT id, grp FROM (SELECT * FROM items ORDER BY grp, id LIMIT 2) s ORDER BY id"
      candidate = "SELECT id, grp FROM (SELECT * FROM items ORDER BY grp LIMIT 2) s ORDER BY id"
      expect(forward_only(original, candidate).match?).to be(true)

      expect(fields(both(original, candidate))).to eq(match: false, mode: :ordered, rule: :value, load_order: :reverse)
    end

    it "catches a LATERAL top-1 that drops its secondary sort key" do
      lateral = lambda do |keys|
        "SELECT g.grp, x.id FROM (SELECT DISTINCT grp FROM items) g CROSS JOIN LATERAL " \
          "(SELECT i.id FROM items i WHERE i.grp = g.grp ORDER BY #{keys} LIMIT 1) x ORDER BY g.grp"
      end
      original = lateral.call("i.label, i.id")
      candidate = lateral.call("i.label")
      expect(forward_only(original, candidate).match?).to be(true)

      expect(fields(both(original, candidate))).to eq(match: false, mode: :ordered, rule: :value, load_order: :reverse)
    end

    it "catches a DISTINCT that keeps another representative of equal intervals" do
      original = "SELECT iv FROM items WHERE id = 1"
      candidate = "SELECT DISTINCT iv FROM items WHERE grp = 1 AND label = 'x'"
      expect(forward_only(original, candidate).match?).to be(true)

      expect(fields(both(original, candidate))).to eq(match: false, mode: :multiset, rule: :multiset,
                                                      load_order: :reverse)
    end

    it "catches a DISTINCT that keeps another representative under a nondeterministic collation" do
      conn.exec(<<~SQL)
        CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE words (id integer PRIMARY KEY, w text COLLATE ci)
      SQL
      rows = rows_of("words", %w[id w], [1, "a"], [2, "A"])
      original = "SELECT w FROM words WHERE id = 1"
      candidate = "SELECT DISTINCT w FROM words"
      expect(forward_only(original, candidate, rows:).match?).to be(true)

      expect(fields(both(original, candidate, rows:))).to eq(match: false, mode: :multiset, rule: :multiset,
                                                             load_order: :reverse)
    end
  end

  describe "a correct rewrite" do
    it "matches in both orders" do
      original = "SELECT id, grp FROM (SELECT * FROM items ORDER BY grp, id LIMIT 2) s ORDER BY id"
      candidate = "SELECT id, grp FROM items WHERE id IN (SELECT id FROM items ORDER BY grp, id LIMIT 2) ORDER BY id"

      expect(fields(both(original, candidate))).to eq(match: true, mode: :ordered, rule: nil, load_order: nil)
    end
  end

  describe "refusals" do
    it "refuses when the forward run refuses, and says which run it was" do
      original = "SELECT id, grp FROM items ORDER BY grp LIMIT 2"

      expect(fields(both(original, original))).to eq(match: false, mode: :ordered, rule: :unsupported_order,
                                                     load_order: :forward)
    end
  end

  describe "foreign keys" do
    let(:join) { "SELECT c.id, p.id FROM child c JOIN parent p ON p.id = c.parent_id" }
    let(:semi) { "SELECT c.id, c.parent_id FROM child c WHERE EXISTS (SELECT FROM parent p WHERE p.id = c.parent_id)" }

    it "reverses each table's rows but keeps parents before children" do
      rows = rows_of("parent", %w[id], [1], [2]) + rows_of("child", %w[id parent_id], [10, 1], [11, 2], [12, 2])
      scan = "SELECT string_agg(id::text, ',') FROM child"

      expect(fields(both(join, semi, rows:))).to include(match: true, load_order: nil)
      expect(fields(both(scan, "SELECT '10,11,12'", rows:))).to include(match: false, load_order: :reverse)
    end

    it "keeps rows of different tables in their order when the tables interleave" do
      rows = rows_of("child", %w[id parent_id], [9, nil]) + rows_of("parent", %w[id], [1]) +
             rows_of("child", %w[id parent_id], [10, 1])

      expect(fields(both(join, semi, rows:))).to include(match: true, load_order: nil)
    end

    it "can't reverse a table whose foreign key references itself, so that reverse load fails" do
      conn.exec("CREATE TABLE node (id integer PRIMARY KEY, up integer REFERENCES node)")
      rows = rows_of("node", %w[id up], [1, nil], [2, 1])

      expect { both("SELECT id FROM node", "SELECT id FROM node", rows:) }
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e| expect([e.rule, e.index]).to eq([:fixture_load_failed, 0]) }
    end

    it "keeps raw inserts in their order, after the rows" do
      rows = rows_of("parent", %w[id], [1])
      inserts = ["INSERT INTO parent VALUES (2)", "INSERT INTO child VALUES (10, 1), (11, 2)"]

      expect(fields(both(join, semi, rows:, inserts:))).to include(match: true, load_order: nil)
    end
  end
end
