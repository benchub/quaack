# frozen_string_literal: true

require "quaack/enclave/fuzz_sizes"

# Task 20261012-31: how many tables the two queries read, which the
# rewrite_test message carries so the driver claims enumerate's bound only
# when it gives each table a row.
RSpec.describe "Quaack::Enclave::FuzzSizes.count" do
  def count(*sqls) = Quaack::Enclave::FuzzSizes.count(*sqls)

  it "counts the distinct tables both queries name" do
    original = "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id"
    rewrite = "SELECT o.id FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.users u WHERE u.id = o.user_id)"
    expect(count(original, rewrite)).to eq(2)
    expect(count(original, "SELECT li.id FROM public.line_items li")).to eq(3)
    expect(count("SELECT o.id FROM public.orders o", "SELECT o.id FROM public.orders o WHERE o.id > $1")).to eq(1)
  end

  it "says MAX_TABLES for that many tables or more, and 0 for none" do
    six = (1..6).map { "public.t#{it}" }.join(", ")
    expect(count("SELECT 1 FROM #{six}")).to eq(Quaack::Protocol::FuzzResult::MAX_TABLES)
    expect(count("SELECT 1", "not sql")).to eq(0)
  end

  # Tasks 20261114-222449-1 and -2.
  it "counts a bare relation name as a table, but not a CTE name in scope" do
    expect(count("SELECT * FROM a JOIN public.b ON true")).to eq(2)
    expect(count("SELECT * FROM a")).to eq(1)
    expect(count("WITH c AS (SELECT * FROM public.t) SELECT * FROM c")).to eq(1)
    nested = "WITH x AS (SELECT * FROM public.t) SELECT * FROM (WITH c AS (SELECT 1) SELECT * FROM c) s, x"
    expect(count(nested)).to eq(1)
    expect(count("SELECT * FROM (WITH c AS (SELECT 1) SELECT * FROM c) s, c")).to eq(1)
    expect(count("WITH orders AS (SELECT * FROM orders) SELECT * FROM orders")).to eq(1)
    expect(count("WITH a AS (SELECT * FROM public.t), b AS (SELECT * FROM a) SELECT * FROM b")).to eq(1)
    expect(count("WITH a AS (SELECT * FROM b), b AS (SELECT 1) SELECT * FROM a")).to eq(1)
    expect(count("WITH RECURSIVE r AS (SELECT 1 UNION ALL SELECT * FROM r) SELECT * FROM r")).to eq(0)
  end

  it "counts a self-join once and collapses aliases" do
    expect(count("SELECT 1 FROM public.users a JOIN public.users b ON a.id = b.manager_id")).to eq(1)
    expect(count("SELECT 1 FROM public.users u", "SELECT 1 FROM public.users AS x")).to eq(1)
    expect(count("SELECT 1 FROM users a JOIN users b ON true")).to eq(1)
  end
end
