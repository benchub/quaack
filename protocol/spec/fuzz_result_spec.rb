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

  # Task 20261016-4: why fuzz stopped, a fixed word, and its rounded
  # seconds, never literals.
  it "accepts a report's rewrites only if each one's fuzz_stop is nil or a reason with whole seconds or none" do
    expect(described_class::STOP_REASONS).to eq(%w[dry floor cap deadline unlifted trials])
    sound = { "trials" => 1790 }
    accepted = [nil, { "reason" => "dry", "seconds" => 41, "quiet" => 20 },
                { "reason" => "trials", "seconds" => nil, "quiet" => nil },
                { "reason" => "deadline", "seconds" => 0, "quiet" => nil },
                { "reason" => "unlifted", "seconds" => 22, "quiet" => nil },
                { "reason" => "floor", "seconds" => 30, "quiet" => 0 },
                { "reason" => "cap", "seconds" => 60, "quiet" => 60 }]
    accepted.each { expect(described_class.rewrites?([sound.merge("fuzz_stop" => it)])).to be(true), it.inspect }
    refused = [{ "reason" => "secret", "seconds" => 41, "quiet" => 20 },
               { "reason" => "dry", "seconds" => "41", "quiet" => 20 },
               { "reason" => "dry", "seconds" => 41.5, "quiet" => 20 },
               { "reason" => "dry", "seconds" => 41, "quiet" => 42 },
               { "reason" => "deadline", "seconds" => -1, "quiet" => nil },
               { "reason" => "deadline", "seconds" => described_class::MAX_STOP_SECONDS + 1, "quiet" => nil },
               { "reason" => "dry", "seconds" => nil, "quiet" => 20 },
               { "reason" => "dry", "seconds" => 41, "quiet" => 20, "sql" => "x" },
               { "reason" => "dry", "seconds" => 41 },
               { "reason" => "dry", "seconds" => 41, "quiet" => 20, quiet: 1 },
               { reason: "dry", seconds: 41, quiet: 20 },
               { "reason" => "dry", "seconds" => 41, "why" => "x" },
               "dry", [["dry", 41, 20]]]
    refused.each { expect(described_class.rewrites?([sound.merge("fuzz_stop" => it)])).to be(false), it.inspect }
  end

  # Task 20261016-4's fix round: the times a reason has, so no record says
  # what no stop could. Only a spec's trial count gives no seconds; dry,
  # floor and cap say how long nothing new came, and a deadline or kills
  # that didn't lift don't.
  it "refuses a fuzz_stop whose times its reason can't have" do
    impossible = [{ "reason" => "dry", "seconds" => nil, "quiet" => nil },
                  { "reason" => "floor", "seconds" => nil, "quiet" => nil },
                  { "reason" => "cap", "seconds" => nil, "quiet" => nil },
                  { "reason" => "deadline", "seconds" => nil, "quiet" => nil },
                  { "reason" => "unlifted", "seconds" => nil, "quiet" => nil },
                  { "reason" => "dry", "seconds" => 41, "quiet" => nil },
                  { "reason" => "floor", "seconds" => 30, "quiet" => nil },
                  { "reason" => "cap", "seconds" => 60, "quiet" => nil },
                  { "reason" => "deadline", "seconds" => 13, "quiet" => 11 },
                  { "reason" => "unlifted", "seconds" => 22, "quiet" => 5 },
                  { "reason" => "trials", "seconds" => 41, "quiet" => 20 },
                  { "reason" => "trials", "seconds" => 41, "quiet" => nil },
                  { "reason" => "trials", "seconds" => nil, "quiet" => 20 }]
    impossible.each { expect(described_class.stop?(it)).to be(false), it.inspect }
  end

  # Task 20261012-4: why the search couldn't test a rewrite is a fixed word.
  it "accepts a report's rewrites only if each one's not_tested is nil or a reason from the list" do
    expect(described_class::NOT_TESTED).to eq(%w[no_tables not_comparable setup_failed no_world unconfirmed
                                                 search_failed fuzz_off])
    sound = { "trials" => 41_200 }
    accepted = [{}, { "not_tested" => nil }, *described_class::NOT_TESTED.map { { "not_tested" => it } }]
    expect(accepted.map { described_class.rewrites?([sound, sound.merge(it)]) }).to all(be(true))
    refused = ["PG::Error: QUAACK_SENTINEL", "out_of_time", :no_world, 3, ["no_world"]]
    expect(refused.map { described_class.rewrites?([sound, sound.merge("not_tested" => it)]) }).to all(be(false))
  end
end
