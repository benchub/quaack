# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/step_nine"

# Step 9 on a schema whose foreign keys form a cycle. Enough foreign keys
# in the cycle whose child columns are all nullable are cut from the load
# order to break it, preferring ones no predicate atom reads. A cut column
# still takes its scenario value, as without the cycle: fixture rows load
# with NULL there and an UPDATE sets it once every row has loaded. A cycle
# with no nullable foreign key still refuses with fk_cycle.
RSpec.describe Quaack::Enclave::Scenarios::Topology do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  def build(sql) = Quaack::Enclave::Scenarios.build(conn, PgQuery.parse(sql))

  def run(rows, sql) = runner.with_fixture(rows) { |tx| tx.query(sql).rows }

  def rows_of(rows, name) = rows.select { |r| r.table.name == name }

  def values(rows, name, column) = rows_of(rows, name).map { |r| r.values[r.columns.index(column)] }

  def tables_in_order(rows) = rows.map { |r| r.table.name }.chunk_while { |x, y| x == y }.map(&:first)

  def expect_fk_cycle(sql)
    expect { build(sql) }.to raise_error(Quaack::Enclave::Scenarios::Error) { |e| expect(e.rule).to eq(:fk_cycle) }
  end

  describe "with two tables and one nullable edge" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.accounts (id integer PRIMARY KEY, name text NOT NULL, course_template_id integer);
        CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts,
          title text NOT NULL);
        ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
      SQL
    end

    let(:join_sql) do
      "SELECT c.id, a.name FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id WHERE c.title = 'x'"
    end

    let(:templates_sql) { "SELECT id, course_template_id FROM fx.accounts" }

    def expected_templates(rows) = rows_of(rows, "accounts").map { |r| [r.values[0], r.values[2]] }.sort_by(&:to_s)

    # Loads rows in both of 9d's load orders and returns what accounts
    # holds each time.
    def loaded_templates(rows)
      [rows, Quaack::Enclave::ResultComparison.reverse_load(rows)].map { |loaded| run(loaded, templates_sql).sort_by(&:to_s) }
    end

    it "builds every scenario, accounts first, with the cut column its parent's key, set after both load orders" do
      scenarios = build(join_sql)
      s1_templates = values(scenarios[:s1], "accounts", "course_template_id")
      expect(s1_templates).not_to be_empty
      expect(s1_templates - values(scenarios[:s1], "courses", "id")).to eq([])
      expect(rows_of(scenarios[:s1], "accounts").map(&:deferred)).to all(eq(["course_template_id"]))
      expect(rows_of(scenarios[:s1], "courses").map(&:deferred)).to all(eq([]))
      scenarios.each_value do |rows|
        next if rows.empty?

        expect(tables_in_order(rows) & %w[accounts courses]).to eq(%w[accounts courses])
        expect(loaded_templates(rows)).to eq([expected_templates(rows)] * 2)
      end
      expect(run(scenarios[:s1], join_sql).size).to be >= 1
    end

    it "keeps the kept foreign key tied to its parent's key" do
      s1 = build(join_sql)[:s1]
      expect(values(s1, "courses", "account_id") - values(s1, "accounts", "id")).to eq([])
    end

    it "runs step 9 end to end, passing an equivalent candidate and disproving another" do
      report = Quaack::Enclave::StepNine.run(
        conn, join_sql,
        ["SELECT c.id, a.name FROM fx.accounts a JOIN fx.courses c ON c.account_id = a.id WHERE c.title = 'x'",
         "SELECT c.id, a.name FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id"]
      )
      expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil], [false, :row_count]])
      expect(report.untested).to eq([])
    end

    describe "with a query that joins on the nullable edge" do
      let(:canvas_sql) do
        "SELECT a.id, a.name, c.title FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id " \
          "WHERE a.name = 'x' ORDER BY a.course_template_id DESC, a.id"
      end

      it "cuts the edge it reads, and loads its value after both load orders" do
        scenarios = build(canvas_sql)
        expect(rows_of(scenarios[:s1], "accounts").map(&:deferred)).to all(eq(["course_template_id"]))
        expect(values(scenarios[:s1], "accounts", "course_template_id")).not_to include(nil)
        scenarios.each_value do |rows|
          expect(loaded_templates(rows)).to eq([expected_templates(rows)] * 2) unless rows.empty?
        end
        expect(run(scenarios[:s1], canvas_sql).size).to be >= 1
      end

      it "builds when a filter atom reads the cut column, giving it the atom's value" do
        s1 = build("SELECT a.id FROM fx.accounts a WHERE a.course_template_id = 5")[:s1]
        expect(values(s1, "accounts", "course_template_id")).to include("5")
        expect(run(s1, "SELECT a.id FROM fx.accounts a WHERE a.course_template_id = 5").size).to be >= 1
      end

      it "passes a correct rewrite, and disproves one that adds IS NULL on the cut column or drops it as a sort key" do
        report = Quaack::Enclave::StepNine.run(
          conn, canvas_sql,
          ["SELECT a.id, a.name, c.title FROM fx.courses c JOIN fx.accounts a ON a.course_template_id = c.id " \
           "WHERE a.name = 'x' ORDER BY a.course_template_id DESC, a.id",
           "SELECT a.id, a.name, c.title FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id " \
           "WHERE a.name = 'x' AND a.course_template_id IS NULL ORDER BY a.course_template_id DESC, a.id",
           "SELECT a.id, a.name, c.title FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id " \
           "WHERE a.name = 'x' ORDER BY a.id"]
        )
        expect(report.results.map { |r| [r.passed, r.rule] })
          .to eq([[true, nil], [false, :row_count], [false, :value]])
        expect(report.untested).to eq([])
      end
    end

    it "gives an orphan group its cut column's parent row, so every scenario loads both ways round" do
      conn.exec("CREATE TABLE fx.notes (id integer PRIMARY KEY, account_name text NOT NULL)")
      scenarios = build("SELECT n.id FROM fx.notes n JOIN fx.accounts a ON a.name = n.account_name")
      s4 = scenarios[:s4]
      expect(rows_of(s4, "accounts").size).to be > rows_of(scenarios[:s1], "accounts").size
      expect(values(s4, "accounts", "course_template_id") - values(s4, "courses", "id")).to eq([])
      scenarios.each_value do |rows|
        expect(loaded_templates(rows)).to eq([expected_templates(rows)] * 2) unless rows.empty?
      end
    end

    it "ties the cut column to its parent's key class, as without the cycle" do
      conn.exec("CREATE TABLE fx.notes (id integer PRIMARY KEY, course_ref integer)")
      sql = "SELECT n.id FROM fx.notes n JOIN fx.courses c ON c.id = n.course_ref"
      schema = Quaack::Enclave::ArenaSchema.load_closure(conn, [tn("notes"), tn("courses")])
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: schema.column_names)
      topology = Quaack::Enclave::Scenarios::Topology.new(schema, atoms)
      expect(topology.cut_columns(tn("accounts"))).to eq(["course_template_id"])
      expect(topology.keyed?(tn("accounts"), "course_template_id")).to be(true)
      expect(topology.slot(tn("accounts"), "course_template_id")).to eq(topology.slot(tn("courses"), "id"))
      expect(topology.keyed?(tn("courses"), "account_id")).to be(true)
    end
  end

  describe "with two nullable edges" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.accounts (id integer PRIMARY KEY, course_template_id integer);
        CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer REFERENCES fx.accounts);
        ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
      SQL
    end

    def cuts(sql)
      schema = Quaack::Enclave::ArenaSchema.load_closure(conn, [tn("accounts")])
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: schema.column_names)
      topology = Quaack::Enclave::Scenarios::Topology.new(schema, atoms)
      [tn("accounts"), tn("courses")].map { |t| topology.cut_columns(t) }
    end

    it "cuts just one, preferring the one no atom reads" do
      expect(cuts("SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id"))
        .to eq([[], ["account_id"]])
      expect(cuts("SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id"))
        .to eq([["course_template_id"], []])
      expect(cuts("SELECT a.id FROM fx.accounts a")).to eq([["course_template_id"], []])
    end
  end

  it "breaks a three-table cycle at its one nullable edge" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer PRIMARY KEY, c_id integer);
      CREATE TABLE fx.b (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a, v text NOT NULL);
      CREATE TABLE fx.c (id integer PRIMARY KEY, b_id integer NOT NULL REFERENCES fx.b);
      ALTER TABLE fx.a ADD FOREIGN KEY (c_id) REFERENCES fx.c;
    SQL
    scenarios = build("SELECT c.id FROM fx.c c JOIN fx.b b ON b.id = c.b_id WHERE b.v = 'x'")
    expect(tables_in_order(scenarios[:s1])).to eq(%w[a b c])
    expect(values(scenarios[:s1], "a", "c_id")).not_to include(nil)
    expect(values(scenarios[:s1], "a", "c_id") - values(scenarios[:s1], "c", "id")).to eq([])
    expect(values(scenarios[:s1], "b", "a_id") - values(scenarios[:s1], "a", "id")).to eq([])
    scenarios.each_value { |rows| expect(run(rows, "SELECT count(*) FROM fx.c")[0][0].to_i).to be >= 0 }
    expect(run(scenarios[:s1], "SELECT count(*) FROM fx.c c JOIN fx.b b ON b.id = c.b_id JOIN fx.a a ON a.id = b.a_id")
             .dig(0, 0).to_i).to be >= 1
  end

  it "refuses a cycle with no nullable edge" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer PRIMARY KEY, b_id integer NOT NULL);
      CREATE TABLE fx.b (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id) REFERENCES fx.b;
    SQL
    expect_fk_cycle("SELECT a.id FROM fx.a a")
  end

  it "refuses a cycle whose nullable edge has a NOT NULL column too" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer, k integer, b_id integer, b_k integer NOT NULL, PRIMARY KEY (id, k));
      CREATE TABLE fx.b (id integer, k integer, a_id integer NOT NULL, a_k integer NOT NULL, PRIMARY KEY (id, k),
        FOREIGN KEY (a_id, a_k) REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id, b_k) REFERENCES fx.b;
    SQL
    expect_fk_cycle("SELECT a.id FROM fx.a a")
  end

  it "leaves a nullable foreign key outside any cycle tied to its parent's key, as before" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer REFERENCES fx.accounts,
        title text NOT NULL);
    SQL
    s1 = build("SELECT c.id FROM fx.courses c WHERE c.title = 'x'")[:s1]
    ids = values(s1, "courses", "account_id")
    expect(ids).not_to include(nil)
    expect(ids - values(s1, "accounts", "id")).to eq([])
    expect(s1.map(&:deferred)).to all(eq([]))
  end
end
