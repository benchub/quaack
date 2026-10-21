# frozen_string_literal: true

require "quaack/protocol/own_rewrites"

RSpec.describe Quaack::Protocol::OwnRewrites do
  let(:entry) do
    { "index" => 1, "sql" => "SELECT $1", "outcome" => "rejected", "rule" => "failed_to_plan", "rewrite" => nil }
  end

  it "passes nil, an empty list, and entries of QUAACK's own fields" do
    kept = entry.merge("outcome" => "accepted", "rule" => nil, "rewrite" => "rewrite_3")
    expect([nil, [], [entry, kept], [entry.transform_values { nil }]].map { described_class.valid?(it) })
      .to all(be(true))
  end

  it "refuses a rule that isn't a word, an unknown outcome or name, other keys, or a list that isn't one" do
    bad = [entry.merge("rule" => "no such rule"), entry.merge("outcome" => "maybe"),
           entry.merge("rewrite" => "orders"), entry.merge("index" => "1"), entry.merge("sql" => 1),
           entry.merge("extra" => 1), entry.except("sql")]
    expect([*bad.map { [it] }, entry, "x"].map { described_class.valid?(it) }).to all(be(false))
  end
end
