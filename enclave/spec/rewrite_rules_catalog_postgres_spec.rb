# frozen_string_literal: true

require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/catalog_shadow"
require_relative "support/production_server"

# The columns rewrite-rules' Catalog lists for a table, and which of them a
# UNION can compare, on a real server.
RSpec.describe Quaack::Enclave::RewriteRules::Catalog do
  subject(:catalog) { described_class.new(conn) }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }

  after do
    conn.close
    production.drop
  end

  def columns(table) = catalog.columns("public", table).to_h { [it.name, it.comparable] }

  before do
    conn.exec(<<~SQL)
      CREATE TYPE public.mood AS ENUM ('ok');
      CREATE TYPE public.int4 AS (n integer);
      CREATE DOMAIN public.small AS integer;
      CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.t (id int, gone int, name varchar(10), born timestamptz, doc json, docb jsonb,
                             tags text[], mood public.mood, pair public.int4, size public.small,
                             nick text COLLATE public.loose, plain text COLLATE "C", key uuid);
      ALTER TABLE public.t DROP COLUMN gone;
    SQL
  end

  it "lists a table's columns in the table's order, without dropped or system columns" do
    expect(columns("t").keys).to eq(%w[id name born doc docb tags mood pair size nick plain key])
  end

  it "calls a column comparable when it's an enum or a built-in type known to hash and sort" do
    expect(columns("t").slice("id", "name", "born", "mood", "plain", "key").values).to all(be(true))
  end

  it "doesn't call json, an array, a composite type named for a built-in one, or a domain comparable" do
    expect(columns("t").slice("doc", "docb", "tags", "pair", "size")).to eq(
      "doc" => false, "docb" => false, "tags" => false, "pair" => false, "size" => false
    )
  end

  it "doesn't call a column comparable when its collation isn't deterministic" do
    expect(columns("t").slice("nick", "plain")).to eq("nick" => false, "plain" => true)
  end

  # The cache is keyed by schema and table (task 20261002-5).
  it "keeps apart the columns of two tables of one name in different schemas" do
    conn.exec("CREATE SCHEMA other; CREATE TABLE other.t (other_id int)")

    expect([columns("t").keys.first, catalog.columns("other", "t").map(&:name)]).to eq(["id", %w[other_id]])
  end

  it "gives no columns for a table that doesn't exist" do
    expect(columns("missing")).to eq({})
  end

  # Task 20261007-43: an INCLUDE column isn't part of the key, so a key
  # needn't be selected with it, nor it be not null.
  it "lists a unique index's key columns as a candidate key, without its INCLUDE columns" do
    conn.exec("CREATE TABLE public.inc (a int, b int, c int, UNIQUE (a) INCLUDE (b), UNIQUE (c, a) INCLUDE (b))")

    expect(catalog.keys("public", "inc")).to eq([["a"], %w[c a]])
  end

  it "reads a table's keys once" do
    conn.exec("CREATE TABLE public.once (a int, CONSTRAINT once_a UNIQUE (a))")
    first = catalog.keys("public", "once")
    conn.exec("ALTER TABLE public.once DROP CONSTRAINT once_a")

    expect([first, catalog.keys("public", "once"), described_class.new(conn).keys("public", "once")])
      .to eq([[["a"]], [["a"]], []])
  end

  it "says whether a query analyzes on its own, with placeholders Postgres types or makes text", :aggregate_failures do
    {
      "SELECT t.id FROM public.t WHERE t.id = $2" => true,
      "SELECT $1 AS label, t.id FROM public.t" => true,
      "SELECT t.id FROM public.t WHERE t.id = outer_t.id" => false,
      "SELECT id FROM public.t WHERE missing = $1" => false,
      "SELECT t.id FROM nowhere t" => false
    }.each do |sql, analyzes|
      expect(catalog.self_contained?(sql)).to be(analyzes), sql
    end
    expect(conn.exec("SELECT count(*) FROM pg_catalog.pg_prepared_statements").getvalue(0, 0)).to eq("0")
  end

  it "says whether a query analyzes on its own inside a transaction, which a failure doesn't end" do
    conn.transaction do
      expect(catalog.self_contained?("SELECT t.id FROM public.t WHERE t.id = outer_t.id")).to be(false)
      expect(catalog.self_contained?("SELECT t.id FROM public.t WHERE t.id = $1")).to be(true)
      expect(conn.exec("SELECT 1").getvalue(0, 0)).to eq("1")
    end
  end

  it "names a type as the column's type is named, with its modifiers, or nil when it can't", :aggregate_failures do
    {
      "int4" => "integer",
      "pg_catalog.int4" => "integer",
      "numeric(5, 1)" => "numeric(5,1)",
      "numeric" => "numeric",
      "varchar(10)" => "character varying(10)",
      "public.mood" => "mood",
      "public.missing" => nil,
      "int4 junk(" => nil,
      "int4, 1" => nil,
      "int4 FROM public.t" => nil,
      "int4; SELECT 1" => nil
    }.each do |type, name|
      expect(conn.transaction { catalog.type_name(type) }).to eq(name), type
    end
    expect(catalog.column_info("public", "t", "name").type).to eq(catalog.type_name("varchar(10)"))
  end

  it "says whether a query calls a volatile function, refusing what it can't check", :aggregate_failures do
    {
      "SELECT t.id FROM public.t WHERE t.id < random()" => true,
      "SELECT t.id FROM public.t WHERE t.id < pg_catalog.random()" => true,
      "SELECT t.id FROM public.t WHERE lower(t.name) = $1 AND t.born < now()" => false,
      "SELECT t.id FROM public.t FOR UPDATE" => true
    }.each do |sql, volatile|
      expect(catalog.calls_volatile?(sql)).to be(volatile), sql
    end
  end

  # Task 20261007-9: rewrite-rules reads the racetrack's catalog, where
  # public's comparisons, ahead of pg_catalog's on the search_path, say no
  # (see CatalogShadow). The reads still find what's there.
  describe "when public's comparison operators shadow pg_catalog's" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.parent (id date PRIMARY KEY);
        CREATE TABLE public.child (pid date REFERENCES public.parent (id));
        CREATE FUNCTION public.many(integer, integer) RETURNS SETOF integer LANGUAGE sql AS 'SELECT 1';
        CREATE OPERATOR public.### (LEFTARG = integer, RIGHTARG = integer, FUNCTION = public.many);
        SET search_path = public, pg_catalog;
      SQL
    end

    def calls(sql) = [PgQuery.parse(sql).tree]

    it "lists columns, names their types, and finds foreign keys, set-returning calls, and btree families",
       :aggregate_failures do
      CatalogShadow.plant(conn, :operators)

      expect([columns("t").keys, columns("t")["born"], catalog.column_info("public", "t", "born")&.type])
        .to eq([%w[id name born doc docb tags mood pair size nick plain key], true, "timestamp with time zone"])
      expect([catalog.referenced_tables("public", "child", "pid"),
              catalog.strict_foreign_key?(%w[public child], %w[public parent], [%w[pid id]])]).to eq([["parent"], true])
      expect([catalog.row_wise?(calls("SELECT unnest(ARRAY[1])")), catalog.row_wise?(calls("SELECT 1 ### 2")),
              catalog.row_wise?(calls("SELECT lower('a')"))]).to eq([false, false, true])
      expect([catalog.default_btree?("public", "t", "born"), catalog.default_btree?("public", "t", "doc")])
        .to eq([true, false])
    end

    # Task 20261007-32: a public <> that says no would let a key whose
    # triggers are disabled read as binding every row.
    it "doesn't call a foreign key strict when its triggers are disabled" do
      CatalogShadow.plant(conn, :operators)
      conn.exec("ALTER TABLE public.child DISABLE TRIGGER ALL")

      expect(catalog.strict_foreign_key?(%w[public child], %w[public parent], [%w[pid id]])).to be(false)
    end
  end
end
