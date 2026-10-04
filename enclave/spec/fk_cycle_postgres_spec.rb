# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/step_nine"

# Step 9 on a schema whose foreign keys form a cycle. A foreign key in the
# cycle whose child columns are all nullable, and that no predicate atom
# reads, is left out of the load order, and fixture rows leave its columns
# NULL. A cycle with no such foreign key still refuses with fk_cycle.
RSpec.describe Quaack::Enclave::Scenarios::Topology do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  def build(sql) = Quaack::Enclave::Scenarios.build(conn, PgQuery.parse(sql))

  def run(rows, sql) = runner.with_fixture(rows) { |tx| tx.query(sql).rows }

  def rows_of(rows, name) = rows.select { |r| r.table.name == name }

  def values(rows, name, column) = rows_of(rows, name).map { |r| r.values[r.columns.index(column)] }

  def tables_in_order(rows) = rows.map { |r| r.table.name }.chunk_while { |x, y| x == y }.map(&:first)

  # cycle is the table names the error must name, in the order the
  # foreign keys point, back to the first.
  def expect_fk_cycle(sql, cycle)
    expect { build(sql) }.to raise_error(Quaack::Enclave::Scenarios::Error) do |e|
      expect([e.rule, e.cycle]).to eq([:fk_cycle, cycle.map { tn(it) }])
    end
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

    it "builds every scenario, accounts first, with the nullable column NULL, and each loads" do
      scenarios = build(join_sql)
      expect(values(scenarios[:s1], "accounts", "course_template_id")).to all(be_nil)
      expect(values(scenarios[:s1], "accounts", "course_template_id")).not_to be_empty
      scenarios.each_value do |rows|
        next if rows.empty?

        expect(tables_in_order(rows) & %w[accounts courses]).to eq(%w[accounts courses])
        expect(run(rows, "SELECT count(*) FROM fx.courses")).to eq([[rows_of(rows, "courses").size.to_s]])
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

    it "still refuses when an atom reads the nullable column" do
      expect_fk_cycle("SELECT a.id FROM fx.accounts a WHERE a.course_template_id = 5", %w[accounts courses accounts])
    end

    it "still refuses when a join atom reads the nullable column" do
      expect_fk_cycle("SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id",
                      %w[accounts courses accounts])
    end

    it "keeps the cut column out of every key class, and out of what counts as a foreign-key column" do
      conn.exec("CREATE TABLE fx.notes (id integer PRIMARY KEY, course_ref integer)")
      sql = "SELECT n.id FROM fx.notes n JOIN fx.courses c ON c.id = n.course_ref"
      schema = Quaack::Enclave::ArenaSchema.load_closure(conn, [tn("notes"), tn("courses")])
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: schema.column_names)
      topology = Quaack::Enclave::Scenarios::Topology.new(schema, atoms)
      expect(topology.cut_columns(tn("accounts"))).to eq(["course_template_id"])
      expect(topology.keyed?(tn("accounts"), "course_template_id")).to be(false)
      expect(topology.keyed?(tn("courses"), "account_id")).to be(true)
      expect(topology.free_joins).to eq([0])
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
    expect(values(scenarios[:s1], "a", "c_id")).to all(be_nil)
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
    expect_fk_cycle("SELECT a.id FROM fx.a a", %w[a b a])
  end

  it "names a three-table cycle in the order its foreign keys point" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer PRIMARY KEY, b_id integer NOT NULL);
      CREATE TABLE fx.b (id integer PRIMARY KEY, c_id integer NOT NULL);
      CREATE TABLE fx.c (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id) REFERENCES fx.b;
      ALTER TABLE fx.b ADD FOREIGN KEY (c_id) REFERENCES fx.c;
    SQL
    expect_fk_cycle("SELECT b.id FROM fx.b b", %w[b c a b])
  end

  # a's nullable aa_c, which nothing reads, is cut, so the cycle named
  # isn't a -> c -> a, though aa_c's foreign key comes first by name.
  it "names a cycle that's left once a nullable foreign key is cut" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer PRIMARY KEY, aa_c integer, b_id integer NOT NULL);
      CREATE TABLE fx.b (id integer PRIMARY KEY, c_id integer NOT NULL);
      CREATE TABLE fx.c (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (aa_c) REFERENCES fx.c;
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id) REFERENCES fx.b;
      ALTER TABLE fx.b ADD FOREIGN KEY (c_id) REFERENCES fx.c;
    SQL
    expect_fk_cycle("SELECT a.id FROM fx.a a", %w[a b c a])
  end

  it "names only the cycle, not a table outside it that references the cycle" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer PRIMARY KEY, b_id integer NOT NULL);
      CREATE TABLE fx.b (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id) REFERENCES fx.b;
      CREATE TABLE fx.notes (id integer PRIMARY KEY, b_id integer NOT NULL REFERENCES fx.b);
    SQL
    expect_fk_cycle("SELECT n.id FROM fx.notes n", %w[b a b])
  end

  it "refuses a cycle whose nullable edge has a NOT NULL column too" do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id integer, k integer, b_id integer, b_k integer NOT NULL, PRIMARY KEY (id, k));
      CREATE TABLE fx.b (id integer, k integer, a_id integer NOT NULL, a_k integer NOT NULL, PRIMARY KEY (id, k),
        FOREIGN KEY (a_id, a_k) REFERENCES fx.a);
      ALTER TABLE fx.a ADD FOREIGN KEY (b_id, b_k) REFERENCES fx.b;
    SQL
    expect_fk_cycle("SELECT a.id FROM fx.a a", %w[a b a])
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
  end
end
