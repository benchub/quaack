# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenarios"

# The load order on a schema whose foreign keys form a cycle, which a
# counterexample round's inserts and parent rows follow
# (Counterexamples.prepare). Enough foreign keys in the cycle whose child
# columns are all nullable are cut from the load order to break it,
# preferring ones no predicate atom reads. A cycle with no nullable
# foreign key raises fk_cycle. (Task 20261012-4 removed the scenario
# fixtures these once built; counterexamples_fk_cycle_postgres_spec loads
# rows on a cycle.)
RSpec.describe Quaack::Enclave::Scenarios::Topology do
  let(:conn) { racetrack_and_arena.arena.connection }

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  def topology(sql)
    parse = PgQuery.parse(sql)
    schema = Quaack::Enclave::ArenaSchema.load_closure(conn, Quaack::Enclave::Scenarios.query_tables(parse.tree))
    described_class.new(schema, Quaack::Enclave::PredicateAtoms.extract(parse, column_names: schema.column_names))
  end

  # cycle is the table names the error must name, in the order the
  # foreign keys point, back to the first.
  def expect_fk_cycle(sql, cycle)
    expect { topology(sql) }.to raise_error(Quaack::Enclave::Scenarios::Error) do |e|
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

    it "loads accounts first, cutting the nullable edge" do
      cut = topology("SELECT c.id, a.name FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id")
      expect([cut.order, cut.cut_columns(tn("accounts")), cut.cut_columns(tn("courses"))])
        .to eq([[tn("accounts"), tn("courses")], ["course_template_id"], []])
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

  describe "with a nullable edge from a cycle's table to a table outside it" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.regions (id integer PRIMARY KEY);
        CREATE TABLE fx.accounts (id integer PRIMARY KEY, course_template_id integer);
        CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts,
          region_id integer REFERENCES fx.regions);
        ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
      SQL
    end

    it "cuts only the edge that closes the cycle, not the edge to the outside table" do
      schema = Quaack::Enclave::ArenaSchema.load_closure(conn, [tn("accounts")])
      sql = "SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.id = a.course_template_id"
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: schema.column_names)
      topology = Quaack::Enclave::Scenarios::Topology.new(schema, atoms)
      expect([tn("accounts"), tn("courses"), tn("regions")].map { topology.cut_columns(it) })
        .to eq([["course_template_id"], [], []])
    end
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
end
