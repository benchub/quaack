# frozen_string_literal: true

require "quaack/protocol/fuzz_result"

RSpec.describe Quaack::Protocol::FuzzResult do
  it "names the three stages a rewrite_test can be decided in" do
    expect(described_class::STAGES).to eq(%w[fuzz enumerate rewrite-test])
  end

  it "accepts a rewrite_test's stage and trials only as nil, a stage from the list, and a count" do
    accepted = [{}, { "stage" => nil, "trials" => nil }, { "stage" => "fuzz", "trials" => 0 },
                { "stage" => "rewrite-test", "trials" => 41_200 }]
    expect(accepted.map { described_class.rewrite_test?(it) }).to all(be(true))
    refused = [{ "stage" => "Fuzz" }, { "stage" => :fuzz }, { "stage" => "enumerated" }, { "stage" => "x'secret'" },
               { "trials" => -1 }, { "trials" => 1.5 }, { "trials" => "12" }, { "trials" => 10**12 }]
    expect(refused.map { described_class.rewrite_test?(it) }).to all(be(false))
  end

  # Task 20261012-3: enumerate's worlds compared, a count, and the row
  # bound it finished, 0 to 4.
  it "accepts a rewrite_test's worlds only as nil or a count, and its bound only as nil or 0 to 4" do
    accepted = [{ "stage" => "enumerate", "worlds" => 0, "bound" => nil },
                { "stage" => "enumerate", "worlds" => 12_000, "bound" => 0 },
                { "stage" => "rewrite-test", "worlds" => nil, "bound" => 4 }]
    expect(accepted.map { described_class.rewrite_test?(it) }).to all(be(true))
    refused = [{ "worlds" => -1 }, { "worlds" => "3" }, { "worlds" => 10**12 }, { "worlds" => 2.0 },
               { "bound" => 5 }, { "bound" => -1 }, { "bound" => "2" }, { "bound" => 1.0 }, { "bound" => 10**12 }]
    expect(refused.map { described_class.rewrite_test?(it) }).to all(be(false))
    expect(described_class::MAX_BOUND).to eq(4)
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

  # Task 20261012-13: fuzz can put a query's constant's worth of rows in a
  # table, so a size above 4 leaves as 5, "5 or more", and nothing higher.
  it "accepts row counts 1 to 5, 5 meaning 5 or more, and nothing higher" do
    expect((1..5).map { described_class.sizes?([["public", "orders", it]]) }).to all(be(true))
    expect([6, 37, 38, 101].map { described_class.sizes?([["public", "orders", it]]) }).to all(be(false))
    expect(described_class::MAX_SIZE).to eq(5)
  end

  it "accepts a report's rewrites only if each one's sizes and trials pass" do
    sound = { "sizes" => [["public", "orders", 2]], "trials" => 41_200 }
    expect(described_class.rewrites?([sound.merge("sizes" => [["public", "orders", 6]])])).to be(false)
    expect(described_class.rewrites?([sound, {}, { "sizes" => nil, "trials" => nil }])).to be(true)
    expect(described_class.rewrites?([sound, sound.merge("sizes" => [%w[public orders 2]])])).to be(false)
    expect(described_class.rewrites?([sound, sound.merge("trials" => -1)])).to be(false)
  end

  it "accepts a report's rewrites only if each one's worlds and bound pass" do
    sound = { "trials" => 41_200, "worlds" => 900, "bound" => 2 }
    expect(described_class.rewrites?([sound, sound.merge("worlds" => nil, "bound" => nil)])).to be(true)
    expect(described_class.rewrites?([sound, sound.merge("worlds" => "900")])).to be(false)
    expect(described_class.rewrites?([sound, sound.merge("bound" => 7)])).to be(false)
  end
end
