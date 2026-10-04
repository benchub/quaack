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

      # S6's empty group and its single-table copies of accounts leave
      # courses out.
      it "holds S6's accounts with no courses with their cut column NULL, the rest their parent's key" do
        s6 = build(canvas_sql)[:s6]
        templates = values(s6, "accounts", "course_template_id")
        expect(templates.count(nil)).to be >= 1
        expect(templates.compact).not_to be_empty
        expect(templates.compact - values(s6, "courses", "id")).to eq([])
        expect(loaded_templates(s6)).to eq([expected_templates(s6)] * 2)
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

    describe "with an anti join on the kept edge" do
      let(:anti_sql) do
        "SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id"
      end

      it "holds an account with no courses in S6, its cut column NULL, loading both ways round" do
        s6 = build(anti_sql)[:s6]
        lonely = rows_of(s6, "accounts").map { |r| r.values[0] } - values(s6, "courses", "account_id")
        expect(lonely).not_to be_empty
        expect(loaded_templates(s6)).to eq([expected_templates(s6)] * 2)
        expect(run(s6, anti_sql)).to eq(lonely.sort_by(&:to_i).map { |id| [id] })
      end

      # No stored value satisfies c.id IS NULL, so the hit ignores it and
      # builds a course. The copy of the hit's account keeps the hit's
      # course as its template, as without the cycle.
      it "gives the cut column its parent's key wherever the parent builds, a copy included" do
        scenarios = build(anti_sql)
        expect(values(scenarios[:s1], "accounts", "course_template_id").compact).not_to be_empty
        s3_templates = values(scenarios[:s3], "accounts", "course_template_id")
        expect(s3_templates).not_to include(nil)
        expect(s3_templates.tally.values.max).to be >= 2
        scenarios.each_value do |rows|
          expect(values(rows, "accounts", "course_template_id").compact - values(rows, "courses", "id")).to eq([])
          expect(loaded_templates(rows)).to eq([expected_templates(rows)] * 2)
        end
      end

      it "passes NOT EXISTS and disproves an inner join" do
        report = Quaack::Enclave::StepNine.run(
          conn, anti_sql,
          ["SELECT a.id FROM fx.accounts a WHERE NOT EXISTS " \
           "(SELECT 1 FROM fx.courses c WHERE c.account_id = a.id) ORDER BY a.id",
           "SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id"]
        )
        expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil], [false, :row_count]])
        # The same as without the cycle's other edge.
        expect(report.untested).to eq(["c.account_id = a.id"])
      end

      # c.title IS NULL has no value, so the hit's courses row and its copy
      # never build, though courses.id's key class has a value.
      it "loads every scenario when another of its parent's columns has no value" do
        title_sql = "SELECT a.id, a.course_template_id FROM fx.accounts a LEFT JOIN fx.courses c " \
                    "ON c.account_id = a.id WHERE c.title IS NULL ORDER BY a.id"
        scenarios = build(title_sql)
        expect(values(scenarios[:s1], "accounts", "course_template_id").compact).not_to be_empty
        scenarios.each_value do |rows|
          expect(values(rows, "accounts", "course_template_id").compact - values(rows, "courses", "id")).to eq([])
          expect(loaded_templates(rows)).to eq([expected_templates(rows)] * 2)
        end
        expect(run(scenarios[:s3], title_sql)).not_to be_empty
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

  describe "with a third table under accounts, and self-references" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.accounts (id bigint PRIMARY KEY, name text NOT NULL,
          root_account_id bigint REFERENCES fx.accounts, parent_account_id bigint REFERENCES fx.accounts,
          course_template_id bigint, workflow_state text NOT NULL DEFAULT 'active');
        CREATE TABLE fx.enrollment_terms (id bigint PRIMARY KEY,
          root_account_id bigint NOT NULL REFERENCES fx.accounts, name text);
        CREATE TABLE fx.courses (id bigint PRIMARY KEY, name text NOT NULL,
          account_id bigint NOT NULL REFERENCES fx.accounts, root_account_id bigint NOT NULL REFERENCES fx.accounts,
          enrollment_term_id bigint NOT NULL REFERENCES fx.enrollment_terms, workflow_state text NOT NULL);
        ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
      SQL
    end

    let(:anti_sql) do
      "SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id"
    end

    # No stored value satisfies c.id IS NULL, so the hit ignores it and
    # builds a course, which the copy of the hit's account keeps as its
    # template. Every enrollment_terms row still has its account.
    it "loads every scenario of an anti join on the kept edge" do
      scenarios = build(anti_sql)
      expect(rows_of(scenarios[:s3], "accounts")).not_to be_empty
      scenarios.each do |name, rows|
        dangling = values(rows, "enrollment_terms", "root_account_id") - values(rows, "accounts", "id")
        expect(dangling).to eq([]), name.to_s
        expect { run(rows, anti_sql) }.not_to raise_error, name.to_s
      end
    end

    it "passes NOT EXISTS and disproves the wrong rewrites" do
      report = Quaack::Enclave::StepNine.run(
        conn, anti_sql,
        ["SELECT a.id FROM fx.accounts a WHERE NOT EXISTS " \
         "(SELECT 1 FROM fx.courses c WHERE c.account_id = a.id) ORDER BY a.id",
         "SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id",
         "SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NULL ORDER BY a.id"]
      )
      expect(report.results.map(&:passed)).to eq([true, false, false])
      expect(report.results.map(&:rule)).not_to include(:fixture_load_failed)
    end

    let(:template_sql) do
      "SELECT a.id, t.id FROM fx.accounts a JOIN fx.courses t ON t.id = a.course_template_id ORDER BY a.id"
    end

    def pairs(rows, sql) = run(rows, sql).map { |id, template| [id.to_i, template.to_i] }

    # Each account with a template, and the account its template's course
    # belongs to.
    def template_owners(rows)
      pairs(rows, "SELECT a.id, t.account_id FROM fx.accounts a JOIN fx.courses t ON t.id = a.course_template_id")
    end

    it "holds an account whose template is another account's course" do
      scenarios = build(template_sql)
      expect(scenarios.values.flat_map { |rows| template_owners(rows) }.reject { |a, owner| a == owner })
        .not_to be_empty
    end

    it "holds an account with courses and no template" do
      scenarios = build(template_sql)
      found = scenarios.values.flat_map do |rows|
        run(rows, "SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NULL " \
                  "AND EXISTS (SELECT 1 FROM fx.courses c WHERE c.account_id = a.id)")
      end
      expect(found).not_to be_empty
    end

    it "disproves where.missing(:course_template) rewritten as accounts with no courses" do
      report = Quaack::Enclave::StepNine.run(
        conn,
        "SELECT a.id, a.name FROM fx.accounts a LEFT JOIN fx.courses c ON c.id = a.course_template_id " \
        "WHERE c.id IS NULL ORDER BY a.id",
        ["SELECT a.id, a.name FROM fx.accounts a WHERE a.course_template_id IS NULL ORDER BY a.id",
         "SELECT a.id, a.name FROM fx.accounts a WHERE NOT EXISTS " \
         "(SELECT 1 FROM fx.courses c WHERE c.account_id = a.id) ORDER BY a.id"]
      )
      expect(report.results.map(&:passed)).to eq([true, false])
    end

    it "disproves looking a template up by account_id" do
      report = Quaack::Enclave::StepNine.run(
        conn,
        "SELECT c.id, a.id FROM fx.courses c JOIN fx.accounts a ON a.course_template_id = c.id ORDER BY c.id, a.id",
        ["SELECT c.id, a.id FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id ORDER BY c.id, a.id",
         "SELECT c.id, a.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id ORDER BY c.id, a.id"]
      )
      expect(report.results.map(&:passed)).to eq([true, false])
    end

    # A copy of an account keeps its template, so accounts tie on it.
    it "disproves dropping or reversing the sort key's tie-break on the cut column, under LIMIT" do
      order_sql = "SELECT a.id FROM fx.accounts a JOIN fx.courses t ON t.id = a.course_template_id ORDER BY "
      report = Quaack::Enclave::StepNine.run(
        conn, "#{order_sql}a.course_template_id DESC, a.id LIMIT 1",
        ["SELECT a.id FROM fx.courses t JOIN fx.accounts a ON a.course_template_id = t.id " \
         "ORDER BY a.course_template_id DESC, a.id LIMIT 1",
         "#{order_sql}a.id DESC LIMIT 1",
         "#{order_sql}a.course_template_id DESC, a.id DESC LIMIT 1"]
      )
      expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil], [false, :value], [false, :value]])
    end

    # Two accounts that share a template join its course twice.
    it "disproves an inner join on the cut edge rewritten as EXISTS" do
      report = Quaack::Enclave::StepNine.run(
        conn,
        "SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.course_template_id = c.id ORDER BY c.id",
        ["SELECT c.id FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id ORDER BY c.id",
         "SELECT c.id FROM fx.courses c WHERE EXISTS " \
         "(SELECT 1 FROM fx.accounts a WHERE a.course_template_id = c.id) ORDER BY c.id"]
      )
      expect(report.results.map(&:passed)).to eq([true, false])
    end

    # A near miss builds a course, so an account there points at it.
    it "disproves dropping an anti join on the cut edge itself (Rails where.missing)" do
      report = Quaack::Enclave::StepNine.run(
        conn,
        "SELECT a.id, a.name FROM fx.accounts a LEFT JOIN fx.courses c ON c.id = a.course_template_id " \
        "WHERE c.id IS NULL ORDER BY a.id",
        ["SELECT a.id, a.name FROM fx.accounts a WHERE NOT EXISTS " \
         "(SELECT 1 FROM fx.courses c WHERE c.id = a.course_template_id) ORDER BY a.id",
         "SELECT a.id, a.name FROM fx.accounts a ORDER BY a.id"]
      )
      expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil], [false, :row_count]])
    end

    it "disproves dropping the anti join from accounts with a template but no courses" do
      report = Quaack::Enclave::StepNine.run(
        conn,
        "SELECT a.id FROM fx.accounts a JOIN fx.courses t ON t.id = a.course_template_id " \
        "LEFT JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id",
        ["SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NOT NULL AND NOT EXISTS " \
         "(SELECT 1 FROM fx.courses c WHERE c.account_id = a.id) ORDER BY a.id",
         "SELECT a.id FROM fx.accounts a JOIN fx.courses t ON t.id = a.course_template_id ORDER BY a.id"]
      )
      expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil], [false, :row_count]])
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
    expect(s1.map(&:deferred)).to all(eq([]))
  end
end
