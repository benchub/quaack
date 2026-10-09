# frozen_string_literal: true

require "quaack/protocol"

RSpec.describe Quaack::Protocol::CandidateKinds do
  it "names a label's kind" do
    expect(described_class.of("original:top:1")).to eq("original_new_indexes")
    expect(described_class.of("original:combination")).to eq("original_new_indexes")
    expect(described_class.of("rewrite_3:top:2")).to eq("rewrite_new_indexes")
    expect(described_class.of("rewrite_3:none")).to eq("rewrite_same_indexes")
    expect(described_class.of("original:none")).to be_nil
  end

  it "accepts a top whose entries all carry a listed kind" do
    expect(described_class.valid?([{ "kind" => "rewrite_same_indexes" }, { kind: "original_new_indexes" }])).to be(true)
    expect(described_class.valid?([])).to be(true)
  end

  it "refuses a top with a missing, unlisted, or non-String kind, or one that isn't a list of Hashes" do
    expect(described_class.valid?([{ "label" => "a" }])).to be(false)
    expect(described_class.valid?([{ "kind" => "SELECT secret" }])).to be(false)
    expect(described_class.valid?([{ "kind" => 1 }])).to be(false)
    expect(described_class.valid?(["rewrite_same_indexes"])).to be(false)
    expect(described_class.valid?(nil)).to be(false)
  end
end
