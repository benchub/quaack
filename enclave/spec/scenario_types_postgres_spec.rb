# frozen_string_literal: true

require "bigdecimal"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/arena_schema"
require "quaack/enclave/scenarios"

# Step 9's values for the types beyond numbers, text, and dates (20261003-27):
# ranges, geometric types, bit strings, arrays, narrow numerics, and the
# columns of a multi-column unique index. Every scenario must load, with no
# group left out for colliding on a unique key.
RSpec.describe Quaack::Enclave::Scenarios do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before { conn.exec("CREATE SCHEMA fx") }

  def builder(sql) = described_class::Builder.new(conn, PgQuery.parse(sql))

  def run(rows, sql) = runner.with_fixture(rows) { |tx| tx.query(sql).rows }

  def values(rows, name, column)
    rows.select { |r| r.table.name == name }.map { |r| r.values[r.columns.index(column)] }
  end

  def loads_every_scenario(scenarios, table)
    count = table.split(",").map { "(SELECT count(*) FROM #{it})" }.join(" + ")
    scenarios.each_value do |rows|
      expect(run(rows, "SELECT #{count}")).to eq([[rows.size.to_s]])
    end
  end

  def builds_and_loads(sql, table)
    b = builder(sql)
    scenarios = b.build
    expect(b.dropped).to eq(0)
    loads_every_scenario(scenarios, table)
    scenarios
  end

  def column(table, name)
    Quaack::Enclave::ArenaSchema.load(conn, [tn(table)]).column(tn(table), name)
  end

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  it "fills plain and unique range columns" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, r int4range NOT NULL, ur int4range NOT NULL UNIQUE,
        nr numrange NOT NULL UNIQUE, dr daterange NOT NULL UNIQUE, tr tstzrange NOT NULL UNIQUE,
        ir int8range NOT NULL UNIQUE);
    SQL
    scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
    expect(values(scenarios[:s1], "t", "r")).to all(eq("empty"))
    expect(values(scenarios[:s3], "t", "ur").uniq.size).to eq(scenarios[:s3].size)
  end

  it "fills plain geometric columns, and ones an expression unique index reads" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, pt point NOT NULL, ls lseg NOT NULL, ln line NOT NULL,
        bx box NOT NULL, pa path NOT NULL, pg polygon NOT NULL, ci circle NOT NULL,
        upt point NOT NULL, ubx box NOT NULL, uci circle NOT NULL, upg polygon NOT NULL);
      CREATE UNIQUE INDEX ON fx.t ((upt[0]));
      CREATE UNIQUE INDEX ON fx.t (area(ubx));
      CREATE UNIQUE INDEX ON fx.t (radius(uci));
      CREATE UNIQUE INDEX ON fx.t (area(upg::path));
    SQL
    scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
    expect(values(scenarios[:s1], "t", "pt")).to all(eq("(0,0)"))
  end

  it "pads a bit(n) column to its length, plain and unique" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, b bit(8) NOT NULL, ub bit(4) NOT NULL UNIQUE,
        vb varbit(6) NOT NULL UNIQUE);
    SQL
    scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
    expect(values(scenarios[:s1], "t", "b")).to all(eq("00000000"))
  end

  it "fills unique array columns with one element of the element type's distinct values" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, ids bigint[] NOT NULL UNIQUE,
        guids varchar[] NOT NULL UNIQUE, nums numeric(5,2)[] NOT NULL UNIQUE, us uuid[] NOT NULL UNIQUE,
        rs int4range[] NOT NULL UNIQUE, plain bigint[] NOT NULL);
    SQL
    scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
    ids = values(scenarios[:s3], "t", "ids")
    expect(ids.uniq.size).to eq(ids.size)
    expect(values(scenarios[:s1], "t", "plain")).to all(eq("{}"))
  end

  it "fills unique jsonb, uuid, and plain json columns" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, j jsonb NOT NULL UNIQUE, js json NOT NULL,
        u uuid NOT NULL UNIQUE);
    SQL
    builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
  end

  it "fills unique narrow numerics" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, sm smallint NOT NULL UNIQUE,
        sc numeric(5,2) NOT NULL UNIQUE, pd numeric(12,2) NOT NULL UNIQUE, tiny numeric(2,0) NOT NULL UNIQUE,
        plain numeric(5,2) NOT NULL);
    SQL
    builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
  end

  it "keeps a split group's join key inside a narrow numeric type" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.a (id integer PRIMARY KEY, k smallint NOT NULL, n numeric(5,2) NOT NULL, v text);
      CREATE TABLE fx.b (id integer PRIMARY KEY, k smallint NOT NULL, n numeric(5,2) NOT NULL);
    SQL
    scenarios = builds_and_loads("SELECT a.id FROM fx.a a JOIN fx.b b ON a.k = b.k AND a.n = b.n WHERE a.v = 'x'",
                                 "fx.a,fx.b")
    s1 = scenarios[:s1]
    joined = run(s1, "SELECT count(*) FROM fx.a a JOIN fx.b b ON a.k = b.k")[0][0].to_i
    # Each join's near miss splits its group, so fewer rows join than a has.
    expect(joined).to be < values(s1, "a", "k").size
  end

  describe "Values#nth for narrow numerics" do
    let(:values_for) { described_class::Values.new(conn) }

    before do
      conn.exec("CREATE TABLE fx.t (sm smallint, sc numeric(5,2), tiny numeric(2,0), big bigint)")
    end

    it "gives distinct values that fit, for numbers past the type's range" do
      %w[sm sc tiny].each do |name|
        col = column("t", name)
        numbers = [1, 5, 99, 999, 50_001, 100_001, 100_005]
        nths = numbers.map { |n| values_for.nth(col, n) }
        expect(nths.map { |s| BigDecimal(s) }.uniq.size).to eq(numbers.size), "#{name}: #{nths}"
      end
    end

    it "keeps a wide type's number as it is" do
      expect(values_for.nth(column("t", "big"), 100_005)).to eq("100005")
      expect(values_for.nth(column("t", "sm"), 5)).to eq("5")
    end

    it "tells apart what two typmods of one type read" do
      conn.exec("ALTER TABLE fx.t ADD wide numeric(20,2)")
      expect(values_for.readable?(column("t", "wide"), "99999999")).to be(true)
      expect(values_for.readable?(column("t", "sc"), "99999999")).to be(false)
    end
  end

  describe "a multi-column unique index" do
    it "varies one column that takes distinct values, and gives the rest their typical value" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, root_account_ids bigint[] NOT NULL,
          login text NOT NULL, span tstzrange NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (root_account_ids, login);
        CREATE UNIQUE INDEX ON fx.users (span, login);
      SQL
      scenarios = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")
      s3 = scenarios[:s3]
      expect(values(s3, "users", "root_account_ids")).to all(eq("{}"))
      expect(values(s3, "users", "span")).to all(eq("empty"))
      expect(values(s3, "users", "login").uniq.size).to eq(s3.size)
    end

    it "still varies a column that a single-column unique index covers too" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, ids bigint[] NOT NULL UNIQUE, login text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (ids, login);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "ids").uniq.size).to eq(s3.size)
    end

    it "varies a column the query's predicate doesn't constrain" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, root_account_ids bigint[] NOT NULL, login text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (login, root_account_ids);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE login = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "root_account_ids").uniq.size).to eq(s3.size)
    end
  end
end
