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
end
