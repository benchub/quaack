# frozen_string_literal: true

require "bigdecimal"
require "json"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/arena_schema"
require "quaack/enclave/error_filter"
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

  it "fills unique arrays of a domain over a domain, and domains over a domain over an array" do
    conn.exec(<<~SQL)
      CREATE DOMAIN fx.small AS smallint; CREATE DOMAIN fx.tiny AS fx.small CHECK (VALUE >= 0);
      CREATE DOMAIN fx.codes AS varchar(3)[]; CREATE DOMAIN fx.labels AS fx.codes;
      CREATE TABLE fx.t (id integer PRIMARY KEY, v text, ts fx.tiny[] NOT NULL UNIQUE,
        ls fx.labels NOT NULL UNIQUE, plain fx.labels NOT NULL);
    SQL
    scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
    %w[ts ls].each do |name|
      got = values(scenarios[:s3], "t", name)
      expect(got.uniq.size).to eq(got.size)
      expect(got).to all(match(/\A\{[^,]+\}\z/))
    end
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

  it "keeps a split group's join key inside the narrowest type of its slot" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.a (id integer PRIMARY KEY, k integer NOT NULL, v text);
      CREATE TABLE fx.b (id integer PRIMARY KEY, k smallint NOT NULL);
      CREATE TABLE fx.c (id integer PRIMARY KEY, k integer NOT NULL);
    SQL
    builds_and_loads("SELECT a.id FROM fx.a a JOIN fx.b b ON a.k = b.k JOIN fx.c c ON b.k = c.k WHERE a.v = 'x'",
                     "fx.a,fx.b,fx.c")
  end

  describe "Values#nth and #readable?" do
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

    it "gives a bit varying with no length as many distinct values as it needs" do
      conn.exec("CREATE TABLE fx.b (vb bit varying UNIQUE)")
      nths = (1..10).map { values_for.nth(column("b", "vb"), it) }
      expect(nths.uniq.size).to eq(10), nths.to_s
      nths.each { conn.exec_params("INSERT INTO fx.b (vb) VALUES ($1)", [it]) }
    end

    it "reads a value as an insert does, so a varchar(n) or char(n) never truncates distinct values" do
      conn.exec("CREATE TABLE fx.s (vc varchar(2) UNIQUE, ch char(2) UNIQUE)")
      %w[vc ch].each do |name|
        col = column("s", name)
        expect(values_for.readable?(col, "k10")).to be(false)
        nths = (1..12).map { values_for.nth(col, it) }
        expect(nths.uniq.size).to eq(12), "#{name}: #{nths}"
        nths.each { conn.exec_params("INSERT INTO fx.s (#{name}) VALUES ($1)", [it]) }
      end
    end
  end

  describe "a column step 9 can't fill" do
    def refusal(sql)
      builder(sql).build
      raise "no refusal"
    rescue described_class::Error => e
      e
    end

    def detail(table, column, type) = { "table" => table, "column" => column, "type" => type }

    it "refuses a plain one, naming its table, column, and type" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, lsn pg_lsn NOT NULL)")
      error = refusal("SELECT id FROM fx.t WHERE v = 'x'")
      expect([error.rule, error.column]).to eq([:unsupported_type, detail("fx.t", "lsn", "pg_lsn")])
      expect(error.message).to eq("unsupported_type: fx.t.lsn (pg_lsn)")
    end

    it "leaves a nullable one NULL when the query doesn't read it, unique or not" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, lsn pg_lsn, ulsn pg_lsn UNIQUE)")
      scenarios = builds_and_loads("SELECT id FROM fx.t WHERE v = 'x'", "fx.t")
      expect(values(scenarios[:s3], "t", "lsn") + values(scenarios[:s3], "t", "ulsn")).to all(be_nil)
    end

    it "still refuses a nullable one the query reads, by name, with a star, or as a whole row" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, lsn pg_lsn)")
      ["SELECT id, lsn FROM fx.t WHERE v = 'x'", "SELECT * FROM fx.t WHERE v = 'x'",
       "SELECT t.* FROM fx.t t WHERE v = 'x'", "SELECT t FROM fx.t t WHERE v = 'x'",
       "SELECT id FROM fx.t WHERE v = 'x' ORDER BY lsn"].each do |sql|
        expect(refusal(sql).column).to eq(detail("fx.t", "lsn", "pg_lsn")), sql
      end
    end

    it "still refuses a nullable unique one whose NULLs collide" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, lsn pg_lsn UNIQUE NULLS NOT DISTINCT)")
      expect(refusal("SELECT id FROM fx.t WHERE v = 'x'").column).to eq(detail("fx.t", "lsn", "pg_lsn"))
    end

    it "refuses a unique one" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, lsn pg_lsn NOT NULL UNIQUE)")
      error = refusal("SELECT id FROM fx.t WHERE v = 'x'")
      expect([error.rule, error.column]).to eq([:unsupported_type, detail("fx.t", "lsn", "pg_lsn")])
    end

    it "refuses a join key, naming a column of its key class" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.a (id integer PRIMARY KEY, l pg_lsn NOT NULL, v text);
        CREATE TABLE fx.b (id integer PRIMARY KEY, l pg_lsn NOT NULL);
      SQL
      error = refusal("SELECT a.id FROM fx.a a JOIN fx.b b ON a.l = b.l WHERE a.v = 'x'")
      expect(error.rule).to eq(:unsupported_type)
      expect([detail("fx.a", "l", "pg_lsn"), detail("fx.b", "l", "pg_lsn")]).to include(error.column)
    end

    it "refuses a unique domain column whose CHECK rejects every distinct value, as domain_check" do
      conn.exec(<<~SQL)
        CREATE DOMAIN fx.big AS integer CHECK (VALUE > 1000000);
        CREATE TABLE fx.t (id integer PRIMARY KEY, v text, code fx.big NOT NULL UNIQUE);
      SQL
      error = refusal("SELECT id FROM fx.t WHERE v = 'x'")
      expect([error.rule, error.column]).to eq([:domain_check, detail("fx.t", "code", "fx.big")])
      expect(error.message).to eq("domain_check: fx.t.code (fx.big)")
    end

    it "refuses a domain over a type it can't fill as unsupported_type" do
      conn.exec(<<~SQL)
        CREATE DOMAIN fx.lsn AS pg_lsn;
        CREATE TABLE fx.t (id integer PRIMARY KEY, v text, l fx.lsn NOT NULL UNIQUE, p fx.lsn NOT NULL);
      SQL
      error = refusal("SELECT id FROM fx.t WHERE v = 'x'")
      expect(error.rule).to eq(:unsupported_type)
      expect([detail("fx.t", "l", "fx.lsn"), detail("fx.t", "p", "fx.lsn")]).to include(error.column)
    end

    it "names schema only, never a value from the query, a default, or a CHECK" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.t (id integer PRIMARY KEY, lsn pg_lsn NOT NULL,
          v text NOT NULL DEFAULT 'SENTINEL_27_DEFAULT' CHECK (v <> 'SENTINEL_27_CHECK'));
      SQL
      error = refusal("SELECT id FROM fx.t WHERE v = 'SENTINEL_27_QUERY'")
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "9")
      expect(JSON.parse(line)["column"]).to eq(detail("fx.t", "lsn", "pg_lsn"))
      [error.message, error.column.to_s, line].each { expect(it).not_to include("SENTINEL") }
    end

    it "does send a column named like a sentinel, so the check above can see one" do
      conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, v text, sentinel_27_name pg_lsn NOT NULL)")
      line = Quaack::Enclave::ErrorFilter.to_egress(refusal("SELECT id FROM fx.t WHERE v = 'x'"), step: "9")
      expect(line).to include("sentinel_27_name")
    end

    it "wraps a unique domain over a narrow numeric" do
      conn.exec(<<~SQL)
        CREATE DOMAIN fx.points AS numeric(5,2); CREATE DOMAIN fx.score AS fx.points;
        CREATE TABLE fx.t (p fx.points, s fx.score);
      SQL
      %w[p s].each do |name|
        nth = described_class::Values.new(conn).nth(column("t", name), 100_005)
        expect(conn.exec_params("SELECT $1::fx.points", [nth]).getvalue(0, 0)).to eq(nth)
      end
    end
  end

  describe "a multi-column unique index" do
    it "varies a range over a boolean, which has too few values" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, active boolean NOT NULL, span int4range NOT NULL,
          UNIQUE (active, span));
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(s3.size).to be > 2
      expect(values(s3, "users", "span").uniq.size).to eq(s3.size)
      expect(values(s3, "users", "active").uniq.size).to eq(1)
    end
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
      expect(values(s3, "users", "login")).to all(eq(""))
    end

    it "lets a wider key use the column a narrower key varies, whichever index came first" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, ids bigint[] NOT NULL, login text NOT NULL);
        CREATE UNIQUE INDEX a_wide ON fx.users (ids, login);
        CREATE UNIQUE INDEX b_narrow ON fx.users (ids);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "ids").uniq.size).to eq(s3.size)
      expect(values(s3, "users", "login")).to all(eq(""))
    end

    it "varies a key's column the join doesn't key, not the join key" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, name text);
        CREATE TABLE fx.enrollments (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
          type varchar(255) NOT NULL, position integer NOT NULL);
        CREATE UNIQUE INDEX ON fx.enrollments (user_id, position);
      SQL
      sql = "SELECT u.id FROM fx.users u JOIN fx.enrollments e ON e.user_id = u.id " \
            "WHERE u.name = 'x' AND e.type = 'StudentEnrollment'"
      s3 = builds_and_loads(sql, "fx.users,fx.enrollments")[:s3]
      positions = values(s3, "enrollments", "position")
      expect(positions.size).to be > 1
      expect(positions.uniq.size).to eq(positions.size)
    end

    it "varies a column whose type takes many values over a boolean" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, active boolean NOT NULL, name text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (active, name);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "name").uniq.size).to eq(s3.size)
      expect(values(s3, "users", "active")).to all(eq("f"))
    end

    it "varies a column whose type takes distinct values over one whose type can't" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, lsn pg_lsn NOT NULL DEFAULT '0/0',
          login text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (lsn, login);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "login").uniq.size).to eq(s3.size)
    end

    it "varies a column with no CHECK over one whose CHECK allows few values" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, kind integer NOT NULL CHECK (kind IN (1, 2)),
          login text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (kind, login);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "login").uniq.size).to eq(s3.size)
      expect(values(s3, "users", "kind")).to all(eq("1"))
    end

    it "varies one column of an expression unique index's keys, not every column it reads" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, kind integer NOT NULL CHECK (kind IN (1, 2)),
          name text NOT NULL, flag boolean NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (kind, lower(name)) WHERE flag;
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "name").uniq.size).to eq(s3.size)
      expect(values(s3, "users", "kind")).to all(eq("1"))
      expect(values(s3, "users", "flag")).to all(eq("f"))
    end

    it "varies an expression unique index's bare key column over one inside an expression" do
      conn.exec(<<~SQL)
        CREATE TABLE fx.users (id bigint PRIMARY KEY, v text, created_at timestamp NOT NULL, login text NOT NULL);
        CREATE UNIQUE INDEX ON fx.users (date_trunc('month', created_at), login);
      SQL
      s3 = builds_and_loads("SELECT id FROM fx.users WHERE v = 'x'", "fx.users")[:s3]
      expect(values(s3, "users", "login").uniq.size).to eq(s3.size)
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
