# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare runs each comparison three times: with the fixture loaded
# forward, again loaded in reverse, and again with each table's rows rotated
# by one. A rewrite that drops a sort key below the top
# level, or keeps a different representative of equal values, matches the
# forward load only because the rows went in in that order.
RSpec.describe Quaack::Enclave::ResultComparison, ".compare_in_load_orders" do
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
    described_class.compare_in_load_orders(runner, rows, inserts:, original:, candidate:)
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

  describe "the rotated load" do
    it "loads each table's rows rotated by one, so a seq scan returns the first row last" do
      scan = "SELECT string_agg(id::text, ',') FROM items"
      expect(runner.with_fixture(described_class.reordered_load(items, :rotated, runner)) { |tx| tx.query(scan).rows })
        .to eq([["2,3,4,5,1"]])

      expect(fields(both(scan, "SELECT '1,2,3,4,5'"))).to include(match: false, load_order: :reverse)
      expect(fields(both(scan, "SELECT '5,4,3,2,1'"))).to include(match: false, load_order: :forward)
    end

    # Three ties, and the pick in the middle: forward and reverse both hand
    # the sort 2 in the middle, so only the rotated load catches it.
    it "catches a tie pick in the middle of an odd-sized group, which forward and reverse agree on" do
      original = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY grp, id) n FROM items WHERE grp = 1) s " \
                 "WHERE n = 2"
      candidate = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY grp) n FROM items WHERE grp = 1) s " \
                  "WHERE n = 2"
      picks = [items, described_class.reverse_load(items)].map do |rows|
        runner.with_fixture(rows, index_scans: false) { |tx| tx.query(candidate).rows }
      end
      expect(picks).to eq([[["2"]], [["2"]]])

      expect(fields(both(original, candidate))).to eq(match: false, mode: :multiset, rule: :multiset,
                                                      load_order: :rotated)
    end
  end

  # A load order that puts every row where an earlier run put it is the same
  # load, so it isn't run again: two rows per table make rotated the same as
  # reverse, and one row makes both the same as forward. The skip is only
  # by the loaded order, so every distinct load still runs.
  describe "skipping a load that repeats an earlier one" do
    let(:loads) { [] }

    before do
      allow(runner).to receive(:with_fixture).and_wrap_original do |original, rows, **options, &block|
        loads << rows.map { [it.table.name, it.values.first] }
        original.call(rows, **options, &block)
      end
    end

    # One table of count rows after another, in id order.
    def runs(*counts)
      counts.each_with_index.flat_map do |count, i|
        rows_of("t#{i}", %w[id], *(1..count).map { [it] })
      end
    end

    before do
      4.times { |i| conn.exec("CREATE TABLE t#{i} (id integer PRIMARY KEY)") }
    end

    def same(rows) = described_class.compare_in_load_orders(runner, rows, original: "SELECT 1", candidate: "SELECT 1")

    it "runs forward, reverse, and rotated when a run has three rows" do
      same(runs(1, 3))

      expect(loads.size).to eq(3)
    end

    it "skips the rotated load when no run has more than two rows, since it's the reverse load" do
      verdict = same(runs(2, 1, 2))

      expect(verdict.match?).to be(true)
      expect(loads.size).to eq(2)
    end

    it "skips the reverse and rotated loads when every run has one row" do
      same(runs(1, 1, 1))

      expect(loads.size).to eq(1)
    end

    it "still runs the first load when there are no rows" do
      same([])

      expect(loads).to eq([[]])
    end

    # Every row count a run can have, in two or three tables: the loads that
    # ran are exactly the distinct loads the three orders make, so skipping
    # never drops a load the orders would have made.
    it "runs exactly the distinct loads of the three orders, for every mix of small runs" do
      shapes = (0..4).to_a.repeated_permutation(2).to_a + (1..3).to_a.repeated_permutation(3).to_a
      shapes.each do |counts|
        loads.clear
        rows = runs(*counts)
        expected = %i[forward reverse rotated].map do |order|
          described_class.reordered_load(rows, order, runner).map { [it.table.name, it.values.first] }
        end.uniq

        same(rows)

        expect(loads).to eq(expected), "runs #{counts.inspect} ran #{loads.size} loads, not #{expected.size}"
      end
    end

    it "still catches the middle pick of a three-row tie, which only the rotated load catches" do
      original = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY grp, id) n FROM items WHERE grp = 1) s " \
                 "WHERE n = 2"
      candidate = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY grp) n FROM items WHERE grp = 1) s " \
                  "WHERE n = 2"

      verdict = both(original, candidate)

      expect(fields(verdict)).to include(match: false, load_order: :rotated)
      expect(loads.size).to eq(3)
    end
  end

  # A later order's positions read the arena's self-referencing keys, so an
  # earlier run that ends the comparison must leave that query unrun
  # (distinct_loads is lazy). The forward order reads none.
  describe "the later load orders after an earlier run ends the comparison" do
    let(:key_reads) { [] }
    let(:scan_order) { "SELECT string_agg(id::text, ',') FROM items" }

    before do
      allow(runner).to receive(:self_references).and_wrap_original do |original, tables|
        key_reads << tables
        original.call(tables)
      end
    end

    it "reads no self-referencing keys when the forward run ends it" do
      verdict = both(scan_order, "SELECT '5,4,3,2,1'")

      expect(fields(verdict)).to include(match: false, load_order: :forward)
      expect(key_reads).to be_empty
    end

    it "reads them only for the reverse order when the reverse run ends it" do
      verdict = both(scan_order, "SELECT '1,2,3,4,5'")

      expect(fields(verdict)).to include(match: false, load_order: :reverse)
      expect(key_reads.size).to eq(1)
    end

    it "reads them for the reverse and rotated orders when every run matches" do
      verdict = both("SELECT count(*) FROM items", "SELECT 5::int8")

      expect(verdict.match?).to be(true)
      expect(key_reads.size).to eq(2)
    end
  end

  describe "rewrites that match the forward load only by luck" do
    it "catches a subquery that drops its secondary sort key before a LIMIT" do
      original = "SELECT id, grp FROM (SELECT *, row_number() OVER (ORDER BY grp, id) n FROM items) s " \
                 "WHERE n <= 2 ORDER BY id"
      candidate = "SELECT id, grp FROM (SELECT *, row_number() OVER (ORDER BY grp) n FROM items) s " \
                  "WHERE n <= 2 ORDER BY id"
      expect(forward_only(original, candidate).match?).to be(true)

      expect(fields(both(original, candidate))).to eq(match: false, mode: :ordered, rule: :value, load_order: :reverse)
    end

    it "catches a LATERAL top-1 that drops its secondary sort key" do
      lateral = lambda do |keys|
        "SELECT g.grp, x.id FROM (SELECT DISTINCT grp FROM items) g CROSS JOIN LATERAL " \
          "(SELECT i.id, row_number() OVER (ORDER BY #{keys}) n FROM items i WHERE i.grp = g.grp) x " \
          "WHERE x.n = 1 ORDER BY g.grp"
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
    let(:original) { "SELECT id FROM (#{numbered("grp, id")}) s WHERE n <= 2 ORDER BY id" }
    let(:candidate) { "SELECT id FROM (#{numbered("grp")}) s WHERE n <= 2 ORDER BY id" }

    def numbered(keys) = "SELECT id, row_number() OVER (ORDER BY #{keys}) n FROM items"

    # The candidate's pick, sorted by grp alone and cut, in each load order
    # in its own transaction, with the planner free to use indexes.
    def with_indexes
      [items, described_class.reverse_load(items)].map do |rows|
        runner.with_fixture(rows) { |tx| tx.query("SELECT id FROM items ORDER BY grp LIMIT 2").rows }
      end
    end

    it "catches the dropped key even when an index would hand back the ties in id order" do
      conn.exec("CREATE INDEX ON items (grp, id)")
      expect(with_indexes).to eq([[%w[1], %w[2]], [%w[1], %w[2]]])

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

    describe "a table whose foreign key references itself" do
      before { conn.exec("CREATE TABLE node (id integer PRIMARY KEY, up integer REFERENCES node)") }

      # A tree: 1 at the root, 2 and 3 under it, 4 under 2, 5 under 3.
      let(:tree) { rows_of("node", %w[id up], [1, nil], [2, 1], [3, 1], [4, 2], [5, 3]) }
      let(:scan) { "SELECT string_agg(id::text, ',') FROM node" }

      it "reorders the rows level by level, so every parent still loads first" do
        scans = %i[reverse rotated].map do |load_order|
          runner.with_fixture(described_class.reordered_load(tree, load_order, runner)) { |tx| tx.query(scan).rows }
        end

        expect(scans).to eq([[["1,3,2,5,4"]], [["1,3,2,5,4"]]])
      end

      it "loads in every order, and catches a dropped sort key in the reverse load" do
        original = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY up, id) n FROM node WHERE up = 1) s " \
                   "WHERE n = 1"
        candidate = "SELECT id FROM (SELECT id, row_number() OVER (ORDER BY up) n FROM node WHERE up = 1) s WHERE n = 1"

        expect(fields(both(original, original, rows: tree))).to include(match: true, load_order: nil)
        expect(fields(both(original, candidate, rows: tree))).to include(match: false, load_order: :reverse)
      end

      it "puts a row below its deepest parent when two foreign keys reference the table" do
        conn.exec("ALTER TABLE node ADD COLUMN root integer REFERENCES node")
        rows = rows_of("node", %w[id up root], [1, nil, nil], [2, 1, 1], [3, 2, 1], [4, 1, 1])

        expect(described_class.reordered_load(rows, :reverse, runner).map { it.values.first }).to eq(%w[1 4 2 3])
        expect(fields(both("SELECT id FROM node", "SELECT id FROM node", rows:))).to include(match: true)
      end

      # emp has a self-reference (boss) and a reference to another table
      # (dept). Only the first is a self-reference, and the levels and the
      # reordered loads depend on that.
      it "reads only the keys that reference the table itself, not its keys to other tables" do
        conn.exec("CREATE TABLE dept (id integer PRIMARY KEY)")
        conn.exec("CREATE TABLE emp (id integer PRIMARY KEY, boss integer REFERENCES emp, " \
                  "dept integer REFERENCES dept)")

        keys = runner.self_references([table("emp"), table("dept"), table("items")])

        expect(keys).to eq(table("emp") => [[%w[boss], %w[id]]], table("dept") => [], table("items") => [])
      end

      # A composite key, with a row whose key is only partly NULL. MATCH
      # SIMPLE doesn't check such a row, so it has no parent, and sits at the top.
      describe "a composite key" do
        before do
          conn.exec(<<~SQL)
            CREATE TABLE part (a integer, b integer, up_a integer, up_b integer, PRIMARY KEY (a, b),
                               FOREIGN KEY (up_a, up_b) REFERENCES part (a, b))
          SQL
        end

        let(:parts) do
          rows_of("part", %w[a b up_a up_b], [1, 1, nil, nil], [1, 2, 1, 1], [2, 1, 1, 1], [3, 1, 2, 1],
                  [4, 1, 1, nil])
        end
        let(:scan) { "SELECT string_agg(a || '.' || b, ',') FROM part" }

        it "reads the key's columns in order" do
          expect(runner.self_references([table("part")])).to eq(table("part") => [[%w[up_a up_b], %w[a b]]])
        end

        it "reorders by the whole key, keeps a row with a NULL part at the top, and loads in every order" do
          scans = %i[reverse rotated].map do |load_order|
            runner.with_fixture(described_class.reordered_load(parts, load_order, runner)) { |tx| tx.query(scan).rows }
          end

          # Top level 1.1 and 4.1 (its key is half NULL), then 1.2 and 2.1, then 3.1.
          expect(scans).to eq([[["4.1,1.1,2.1,1.2,3.1"]], [["4.1,1.1,2.1,1.2,3.1"]]])
          expect(fields(both(scan, scan, rows: parts))).to include(match: true, load_order: nil)
        end
      end

      # The table's rows come in two runs, with another table's row between.
      # A row of the second run finds no parent in its own run unless it's
      # in that run, so it sits at that run's top, and its parent, in the
      # first run, still loads first.
      it "loads in every order when the table's rows come in more than one run" do
        rows = rows_of("node", %w[id up], [1, nil], [2, 1]) + rows_of("parent", %w[id], [7]) +
               rows_of("node", %w[id up], [3, 2], [4, 3], [5, 1])

        loads = %i[reverse rotated].map do |load_order|
          described_class.reordered_load(rows, load_order, runner).map { [it.table.name, it.values.first] }
        end

        expect(loads).to eq([[%w[node 1], %w[node 2], %w[parent 7], %w[node 5], %w[node 3], %w[node 4]]] * 2)
        expect(fields(both("SELECT id FROM node", "SELECT id FROM node", rows:))).to include(match: true)
      end

      it "still fails the reverse load, as reverse_load_failed, when a parent doesn't match its key's text" do
        rows = rows_of("node", %w[id up], [1, nil], [2, "01"])

        expect { both("SELECT id FROM node", "SELECT id FROM node", rows:) }
          .to raise_error(Quaack::Enclave::ArenaRunner::Error) do |e|
            expect([e.rule, e.step, e.sqlstate, e.index]).to eq([:reverse_load_failed, :load, "23503", 1])
            expect(e.message).to eq("a fixture row failed to load when the fixture was loaded in reverse")
          end
      end
    end

    it "fails a row that loads forward and in reverse but not rotated as rotated_load_failed" do
      conn.exec(<<~SQL)
        CREATE FUNCTION not_first() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.id = 2 AND NOT EXISTS (SELECT FROM parent) THEN RAISE EXCEPTION 'first'; END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER not_first BEFORE INSERT ON parent FOR EACH ROW EXECUTE FUNCTION not_first();
      SQL
      rows = rows_of("parent", %w[id], [1], [2], [3])

      expect { both("SELECT id FROM parent", "SELECT id FROM parent", rows:) }
        .to raise_error(Quaack::Enclave::ArenaRunner::Error) do |e|
          expect([e.rule, e.step, e.sqlstate, e.index]).to eq([:rotated_load_failed, :load, "P0001", 1])
          expect(e.message).to eq("a fixture row failed to load when the fixture was loaded rotated")
        end
    end

    it "keeps a query that fails only in the reverse run a query_failed" do
      sql = "SELECT 1 / ((SELECT array_agg(id) FROM items)[1] - 5) AS q"

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
