# frozen_string_literal: true

require "quaack/protocol"

RSpec.describe Quaack::Protocol::CandidateKinds do
  it "names a label's kind" do
    expect(described_class.of("original:top:1")).to eq("original_new_indexes")
    expect(described_class.of("original:combination")).to eq("original_new_indexes")
    expect(described_class.of("rewrite_3:top:2")).to eq("rewrite_new_indexes")
    expect(described_class.of("rewrite_3:none")).to eq("rewrite_same_indexes")
    expect(described_class.of("original:none")).to be_nil
    expect(described_class.of("original:shared:1")).to eq("original_new_indexes")
    expect(described_class.of("rewrite_2:shared:3")).to eq("rewrite_new_indexes")
  end

  # Task 20261017-2: the labels QUAACK makes itself, and only those.
  it "accepts only QUAACK's own labels" do
    ok = %w[original:none original:combination original:top:1 rewrite_12:set_aside:3 rewrite_1:shared:2]
    expect(ok.map { described_class.label?(it) }).to all(be(true))
    bad = ["original:shared:0", "original:shared", "rewrite_0:none", "rewrite_1:shared:1 ", "x:none",
           "original:shared:1\nSELECT secret", "original:other:1", :"original:none", nil]
    expect(bad.map { described_class.label?(it) }).to all(be(false))
  end

  it "accepts a report's top, labels, and excluded only if each label is QUAACK's own" do
    good = { "top" => [{ "label" => "rewrite_1:shared:1" }], "labels" => [{ "label" => "original:shared:2" }],
             "excluded" => { "original:shared:1" => "not_better" } }
    expect(described_class.labels?(good)).to be(true)
    expect(described_class.labels?({ "top" => [], "labels" => [], "excluded" => {} })).to be(true)
    [{ "top" => [{ "label" => "SELECT secret" }] }, { "top" => [{ "kind" => "rewrite_same_indexes" }] },
     { "labels" => [{ "label" => "original:shared:x" }] }, { "excluded" => { "secret" => "not_better" } },
     { "labels" => ["original:none"] }, { "excluded" => [] }, { "top" => nil }].each do |planted|
      expect(described_class.labels?(good.merge(planted))).to be(false), planted.inspect
    end
  end

  # Task 20261018-31: a label candidate-runs skipped says so with skipped,
  # and that's only ever true or false.
  it "accepts a label's skipped only as true or false" do
    labels = ->(skipped) { { "labels" => [{ "label" => "rewrite_1:shared:1", **skipped }] } }
    [{}, { "skipped" => true }, { "skipped" => false }, { skipped: true }].each do |skipped|
      expect(described_class.labels?(labels.call(skipped))).to be(true), skipped.inspect
    end
    [{ "skipped" => "SELECT secret" }, { "skipped" => nil }, { "skipped" => 1 },
     { skipped: "secret" }].each do |planted|
      expect(described_class.labels?(labels.call(planted))).to be(false), planted.inspect
    end
  end

  # Only a rewrite's shared pairing can be skipped, and a skipped one neither
  # timed out nor has measurements.
  it "accepts skipped as true only on a rewrite's shared pairing that didn't time out and has no measurements" do
    labels = ->(entry) { { "labels" => [entry] } }
    skipped = { "label" => "rewrite_1:shared:1", "skipped" => true, "timed_out" => false, "measurements" => nil }
    expect(described_class.labels?(labels.call(skipped))).to be(true)
    expect(described_class.labels?(labels.call({ label: "rewrite_2:shared:3", skipped: true }))).to be(true)
    %w[original:none original:shared:1 original:top:1 rewrite_1:none rewrite_1:top:1 rewrite_1:combination
       rewrite_1:set_aside:1].each do |label|
      expect(described_class.labels?(labels.call(skipped.merge("label" => label)))).to be(false), label
      expect(described_class.labels?(labels.call(skipped.merge("label" => label, "skipped" => false)))).to be(true)
    end
    [{ "timed_out" => true }, { timed_out: true }, { "measurements" => { "slow" => { "timed_out" => true } } },
     { measurements: {} }].each do |planted|
      expect(described_class.labels?(labels.call(skipped.merge(planted)))).to be(false), planted.inspect
    end
  end

  it "takes a report's ranking only when its top carries listed kinds and every label is QUAACK's own" do
    good = { "top" => [{ "label" => "rewrite_1:shared:1", "kind" => "rewrite_new_indexes" }],
             "labels" => [{ "label" => "original:shared:2" }], "excluded" => { "original:none" => "not_better" } }
    expect(described_class.report?(good)).to be(true)
    expect(described_class.report?(good.merge("top" => [{ "label" => "rewrite_1:shared:1" }]))).to be(false)
    expect(described_class.report?(good.merge("excluded" => { "original:shared:x" => "not_better" }))).to be(false)
    expect(described_class.report?({})).to be(true)
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
