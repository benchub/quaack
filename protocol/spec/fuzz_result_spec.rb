# frozen_string_literal: true

require "quaack/protocol/fuzz_result"

RSpec.describe Quaack::Protocol::FuzzResult do
  it "names the two stages a rewrite_test can be decided in" do
    expect(described_class::STAGES).to eq(%w[fuzz rewrite-test])
  end

  it "accepts a rewrite_test's stage and trials only as nil, a stage from the list, and a count" do
    accepted = [{}, { "stage" => nil, "trials" => nil }, { "stage" => "fuzz", "trials" => 0 },
                { "stage" => "rewrite-test", "trials" => 41_200 }]
    expect(accepted.map { described_class.rewrite_test?(it) }).to all(be(true))
    refused = [{ "stage" => "Fuzz" }, { "stage" => :fuzz }, { "stage" => "enumerate" }, { "stage" => "x'secret'" },
               { "trials" => -1 }, { "trials" => 1.5 }, { "trials" => "12" }, { "trials" => 10**12 }]
    expect(refused.map { described_class.rewrite_test?(it) }).to all(be(false))
  end

  it "accepts sizes only as nil or [schema, table, rows] triples, each table once, with rows a positive count" do
    accepted = [nil, [], [["public", "orders", 2], ["Billing", "line items", 1]]]
    expect(accepted.map { described_class.sizes?(it) }).to all(be(true))
    refused = [[["public", "orders", 0]], [%w[public orders 2]], [%w[public orders]],
               [["public", "orders", 2, "x"]], [["public", "orders", 1], ["public", "orders", 1]],
               [[:public, "orders", 1]], [["public", "o" * 64, 1]], [["", "orders", 1]],
               [["public", "orders", 10**12]], { "public.orders" => 2 }, "2 rows in orders"]
    expect(refused.map { described_class.sizes?(it) }).to all(be(false))
  end
end
