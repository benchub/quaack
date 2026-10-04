# frozen_string_literal: true

require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# The columns the rewrite-rules rules' Catalog lists for a table, and which of them a
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

  it "gives no columns for a table that doesn't exist" do
    expect(columns("missing")).to eq({})
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
end
