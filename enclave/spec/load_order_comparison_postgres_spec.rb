# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare runs each comparison twice: with the fixture loaded forward, and
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
      CREATE TABLE items (id integer PRIMARY KEY, grp integer NOT NULL, label text, iv interval, jb jsonb);
      CREATE TABLE parent (id integer PRIMARY KEY);
      CREATE TABLE child (id integer PRIMARY KEY, parent_id integer REFERENCES parent);
    SQL
  end

  # Loaded in id order, the way a scenario is. grp 1 ties three ways, and
  # within it label ties twice. The two intervals, and the two jsonb
  # values, in grp 1 are equal to Postgres but print differently.
  let(:items) do
    rows_of("items", %w[id grp label iv jb],
            [1, 1, "x", "1 day", '{"a": 1.0}'], [2, 1, "x", "24 hours", '{"a": 1.00}'], [3, 1, "y", "1 day", "{}"],
            [4, 2, "x", "1 day", "{}"], [5, 2, "x", "1 day", "{}"])
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

    it "catches a DISTINCT that keeps another representative of equal jsonb values" do
      original = "SELECT jb FROM items WHERE id = 1"
      candidate = "SELECT DISTINCT jb FROM items WHERE grp = 1 AND label = 'x'"
      expect(forward_only(original, candidate).match?).to be(true)

      expect(fields(both(original, candidate))).to eq(match: false, mode: :multiset, rule: :multiset,
                                                      load_order: :reverse)
    end

    # Intervals compare by value, as the original's own DISTINCT or = does,
    # so the other representative is the same value.
    it "matches a DISTINCT that keeps another representative of equal intervals" do
      original = "SELECT iv FROM items WHERE id = 1"
      candidate = "SELECT DISTINCT iv FROM items WHERE grp = 1 AND label = 'x'"
      expect(runner.with_fixture(described_class.reverse_load(items)) { |tx| tx.query(candidate).rows })
        .to eq([["24:00:00"]])

      expect(fields(both(original, candidate))).to eq(match: true, mode: :multiset, rule: nil, load_order: nil)
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

  describe "an index that orders the ties" do
    let(:original) { "SELECT id FROM (SELECT * FROM items ORDER BY grp, id LIMIT 2) s ORDER BY id" }
    let(:candidate) { "SELECT id FROM (SELECT * FROM items ORDER BY grp LIMIT 2) s ORDER BY id" }

    # Each load order in its own transaction, with the planner free to use
    # indexes.
    def with_indexes
      [items, described_class.reverse_load(items)].map do |rows|
        runner.with_fixture(rows) { |tx| described_class.compare(tx, original:, candidate:).match? }
      end
    end

    it "catches the dropped key even when an index would hand back the ties in id order" do
      conn.exec("CREATE INDEX ON items (grp, id)")
      expect(with_indexes).to eq([true, true])

      expect(fields(both(original, candidate))).to eq(match: false, mode: :ordered, rule: :value, load_order: :reverse)
    end

    it "catches it with an index on the first key only" do
      conn.exec("CREATE INDEX ON items (grp)")

      expect(fields(both(original, candidate))).to eq(match: false, mode: :ordered, rule: :value, load_order: :reverse)
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
      original = "SELECT DISTINCT ON (grp) grp, id FROM items ORDER BY grp"

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
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) do |e|
          expect([e.rule, e.step, e.sqlstate, e.index]).to eq([:reverse_load_failed, :load, "23503", 1])
          expect(e.message).to eq("a fixture row failed to load when the fixture was loaded in reverse")
        end
    end

    it "keeps a query that fails only in the reverse run a query_failed" do
      sql = "SELECT 1 / (SELECT id - 5 FROM items LIMIT 1) AS q"

      expect { both(sql, sql) }.to raise_error(Quaack::Enclave::ArenaRunner::Error) do |e|
        expect([e.rule, e.step, e.sqlstate]).to eq([:query_failed, :query, "22012"])
      end
    end

    it "keeps a failure in the forward load a fixture_load_failed" do
      conn.exec("CREATE TABLE node (id integer PRIMARY KEY, up integer REFERENCES node)")
      rows = rows_of("node", %w[id up], [1, nil], [2, 3])

      expect { both("SELECT id FROM node", "SELECT id FROM node", rows:) }
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e| expect([e.rule, e.index]).to eq([:fixture_load_failed, 1]) }
    end

    it "treats same-named tables in two schemas as different tables" do
      conn.exec(<<~SQL)
        CREATE SCHEMA a; CREATE SCHEMA b;
        CREATE TABLE a.t (id integer PRIMARY KEY);
        CREATE TABLE b.t (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES a.t);
      SQL
      in_schema = lambda do |schema, columns, *values|
        values.map do |v|
          Quaack::Enclave::ArenaRunner::FixtureRow.new(
            table: Quaack::Enclave::TableName.new(schema:, name: "t"), columns:, values: v.map(&:to_s)
          )
        end
      end
      rows = in_schema.call("a", %w[id], [1], [2]) + in_schema.call("b", %w[id a_id], [10, 1], [11, 2])
      scan = "SELECT string_agg(id::text, ',') FROM b.t"

      expect(fields(both(scan, "SELECT '10,11'", rows:))).to include(match: false, load_order: :reverse)
    end

    it "keeps raw inserts in their order, after the rows" do
      rows = rows_of("parent", %w[id], [1])
      inserts = ["INSERT INTO parent VALUES (2)", "INSERT INTO child VALUES (10, 1), (11, 2)"]

      expect(fields(both(join, semi, rows:, inserts:))).to include(match: true, load_order: nil)
      expect(fields(both("SELECT string_agg(id::text, ',' ORDER BY id) FROM child", "SELECT '10,11'", rows:, inserts:)))
        .to eq(match: true, mode: :multiset, rule: nil, load_order: nil)
    end
  end
end
