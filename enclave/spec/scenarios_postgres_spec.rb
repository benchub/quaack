# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/scenarios"

# rewrite-test: scenarios S0 through S6, built from the value pools. Each one must
# load into arena as is, so every row satisfies every constraint.
RSpec.describe Quaack::Enclave::Scenarios do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.customers (id serial PRIMARY KEY, name text NOT NULL,
        region text NOT NULL DEFAULT 'eu',
        score integer NOT NULL CHECK (score BETWEEN 3 AND 5),
        tier text NOT NULL CHECK (tier IN ('gold', 'silver')),
        code text NOT NULL UNIQUE);
      CREATE TABLE fx.orders (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES fx.customers,
        status text NOT NULL, qty integer CHECK (qty > 0), note text);
      CREATE TABLE fx.a (id integer PRIMARY KEY, k integer, v text);
      CREATE TABLE fx.b (id integer PRIMARY KEY, k integer);
    SQL
  end

  let(:join_sql) do
    "SELECT o.id, c.name FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id " \
      "WHERE o.status = 'open' AND o.qty >= 3"
  end

  def build(sql, **) = described_class.build(conn, PgQuery.parse(sql), **)

  def run(rows, sql) = runner.with_fixture(rows) { |tx| tx.query(sql).rows }

  def rows_of(rows, name) = rows.select { |r| r.table.name == name }

  def values(rows, name, column)
    rows_of(rows, name).map { |r| r.values[r.columns.index(column)] }
  end

  describe "with a join and predicates" do
    let(:scenarios) { build(join_sql) }

    it "builds S0 through S6, and each loads, with each table's rows together and parents first" do
      expect(scenarios.keys).to eq(%i[s0 s1 s2 s3 s4 s5 s6])
      expect(scenarios[:s0]).to eq([])
      scenarios.each_value do |rows|
        names = rows.map { |r| r.table.name }.chunk_while { |x, y| x == y }.map(&:first)
        expect(names).to eq(names.uniq)
        expect(names.index("customers")).to be < names.index("orders") if names.include?("orders")
        expect(run(rows, "SELECT count(*) FROM fx.orders")).to eq([[rows_of(rows, "orders").size.to_s]])
      end
    end

    it "gives S1 a hit row, and a near-miss row that each atom's TRUE replacement lets through" do
      parse = PgQuery.parse(join_sql)
      atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: {
                                                        tn("orders") => %w[id customer_id status qty note],
                                                        tn("customers") => %w[id name region score tier code]
                                                      })
      original = run(scenarios[:s1], join_sql).size
      expect(original).to be >= 1
      atoms.each_index.reject { |i| atoms[i].kind == :join }.each do |i|
        loosened = run(scenarios[:s1], Quaack::Enclave::PredicateAtoms.with_true(parse, atoms[i])).size
        expect(loosened).to be > original
      end
    end

    it "keeps NULLs out of S1 and puts them in S2's nullable predicate columns" do
      expect(scenarios[:s1].flat_map(&:values)).not_to include(nil)
      expect(values(scenarios[:s2], "orders", "qty")).to include(nil)
    end

    it "fills required columns the query never names to satisfy their CHECKs, and leaves defaults alone" do
      rows = rows_of(scenarios[:s1], "customers")
      expect(values(scenarios[:s1], "customers", "score").map(&:to_i)).to all(be_between(3, 5))
      expect(values(scenarios[:s1], "customers", "tier")).to all(satisfy { |t| %w[gold silver].include?(t) })
      expect(rows.flat_map(&:columns)).not_to include("region")
    end

    it "fans out the non-unique join key in S3" do
      expect(run(scenarios[:s3], join_sql).size).to be > run(scenarios[:s1], join_sql).size
    end

    it "puts type boundary values in S5's hit rows" do
      expect(values(scenarios[:s5], "orders", "qty")).to include("2147483647")
      expect(run(scenarios[:s5], join_sql).size).to be > run(scenarios[:s1], join_sql).size
    end

    it "gives S6 a group of one, a group of many, and an empty group" do
      counts = run(scenarios[:s6], <<~SQL).map { |r| r[0].to_i }
        SELECT count(o.id) FROM fx.customers c LEFT JOIN fx.orders o ON o.customer_id = c.id GROUP BY c.id
      SQL
      expect(counts).to include(0, 1)
      expect(counts.max).to be >= 3
    end

    it "takes other pool values for an atom when asked for a variant" do
      plain = values(build(join_sql)[:s1], "orders", "qty")
      varied = values(build(join_sql, variants: { 2 => 1 })[:s1], "orders", "qty")
      expect(varied).not_to eq(plain)
    end
  end

  it "puts orphans on both sides of a join with no FK in S4" do
    sql = "SELECT a.id FROM fx.a a JOIN fx.b b ON a.k = b.k WHERE a.v = 'x'"
    scenarios = build(sql)
    count = <<~SQL
      SELECT (SELECT count(*) FROM fx.a WHERE NOT EXISTS (SELECT FROM fx.b WHERE b.k = a.k)),
             (SELECT count(*) FROM fx.b WHERE NOT EXISTS (SELECT FROM fx.a WHERE b.k = a.k))
    SQL
    s1, s4 = scenarios.values_at(:s1, :s4).map { |rows| run(rows, count)[0].map(&:to_i) }
    expect(s4.zip(s1)).to all(satisfy { |four, one| four > one })
  end

  it "fills a required column to satisfy its domain's CHECK" do
    conn.exec(<<~SQL)
      CREATE DOMAIN fx.rank AS integer CHECK (VALUE BETWEEN 7 AND 9);
      CREATE TABLE fx.d (id integer PRIMARY KEY, r fx.rank NOT NULL, v text);
    SQL
    rows = build("SELECT id FROM fx.d WHERE v = 'x'")[:s1]
    expect(values(rows, "d", "r").map(&:to_i)).to all(be_between(7, 9))
    expect(run(rows, "SELECT count(*) FROM fx.d")).to eq([[rows.size.to_s]])
  end

  it "refuses a table with a CHECK it can't satisfy simply" do
    conn.exec("CREATE TABLE fx.c (id integer PRIMARY KEY, lo integer, hi integer, CHECK (lo < hi))")
    expect { build("SELECT id FROM fx.c WHERE lo = 1") }
      .to raise_error(described_class::Error) { |e| expect(e.rule).to eq(:complex_check) }
  end

  def loads_every_scenario(scenarios, table)
    scenarios.each_value { |rows| expect(run(rows, "SELECT count(*) FROM #{table}")).to eq([[rows.size.to_s]]) }
  end

  it "gives distinct values to a column a plain unique index covers" do
    conn.exec("CREATE TABLE fx.u (id integer PRIMARY KEY, email text NOT NULL, qty integer);
               CREATE UNIQUE INDEX u_email ON fx.u (email)")
    scenarios = build("SELECT id FROM fx.u WHERE qty <> 5")
    expect(values(scenarios[:s1], "u", "email").uniq.size).to eq(scenarios[:s1].size)
    loads_every_scenario(scenarios, "fx.u")
  end

  it "treats a partial unique index as always unique" do
    conn.exec("CREATE TABLE fx.u (id integer PRIMARY KEY, email text NOT NULL, qty integer);
               CREATE UNIQUE INDEX u_email ON fx.u (email) WHERE qty IS NOT NULL")
    loads_every_scenario(build("SELECT id FROM fx.u WHERE qty <> 5"), "fx.u")
  end

  it "gives distinct values to a unique column that has a default" do
    conn.exec("CREATE TABLE fx.w (id integer PRIMARY KEY, code text NOT NULL DEFAULT 'x' UNIQUE, v text)")
    loads_every_scenario(build("SELECT id FROM fx.w WHERE v = 'a'"), "fx.w")
  end

  it "loads every scenario on a table with an expression unique index" do
    conn.exec("CREATE TABLE fx.u (id integer PRIMARY KEY, email text NOT NULL, qty integer);
               CREATE UNIQUE INDEX u_email ON fx.u (lower(email))")
    scenarios = build("SELECT id FROM fx.u WHERE qty <> 5")
    # Hit, near miss, and a copy of the hit row: none left out.
    expect(scenarios[:s3].size).to eq(3)
    expect(values(scenarios[:s3], "u", "email").map(&:downcase).uniq.size).to eq(3)
    loads_every_scenario(scenarios, "fx.u")
  end

  it "refuses an expression unique index that calls a function outside pg_catalog" do
    conn.exec("CREATE FUNCTION fx.norm(text) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT lower($1)';
               CREATE TABLE fx.u (id integer PRIMARY KEY, email text NOT NULL);
               CREATE UNIQUE INDEX u_email ON fx.u (fx.norm(email))")
    expect { build("SELECT id FROM fx.u WHERE email = 'a'") }
      .to raise_error(described_class::Error) { |e| expect(e.rule).to eq(:expression_unique_index) }
  end

  # No value satisfies t.id IS NULL on the NOT NULL key, so the atom is
  # ignored, and t.id still takes a value per row. Repeating one would
  # leave S6's many group out.
  it "gives a unique column a value per row when the atom it reads is ignored" do
    conn.exec("CREATE TABLE fx.templates (id bigint PRIMARY KEY, customer_id integer NOT NULL REFERENCES fx.customers)")
    sql = "SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id " \
          "LEFT JOIN fx.templates t ON t.customer_id = c.id WHERE t.id IS NULL"
    builder = described_class::Builder.new(conn, PgQuery.parse(sql))
    s6 = builder.build[:s6]
    expect(values(s6, "templates", "id").size).to eq(4)
    expect(values(s6, "templates", "id").uniq.size).to eq(4)
    expect(builder.dropped).to eq(0)
  end

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)
end
