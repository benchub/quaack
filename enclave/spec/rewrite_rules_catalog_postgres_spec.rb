# frozen_string_literal: true

require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# The columns the 6c rules' Catalog lists for a table, and which of them a
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
end
