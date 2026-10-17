# frozen_string_literal: true

require "quaack/enclave/index_share"

# Task 20261017-2: IndexShare's bound on the extra runs, and its labels.
RSpec.describe Quaack::Enclave::IndexShare do
  def pair(search, name, ratio) = { "search" => search, "name" => name, "ratio" => ratio }

  describe ".choose" do
    it "keeps each candidate's PER_CANDIDATE lowest ratios" do
      scored = [pair("original", "a", 0.9), pair("original", "b", 0.1), pair("original", "c", 0.5),
                pair("original", "d", 0.2), pair("rewrite_1", "a", 0.8)]

      expect(described_class.choose(scored).map { it.values_at("search", "name") })
        .to eq([%w[original b], %w[original d], %w[original c], %w[rewrite_1 a]])
    end

    it "keeps the TOTAL lowest ratios over every candidate" do
      scored = (1..7).flat_map { |n| [pair("rewrite_#{n}", "a", n / 10.0), pair("rewrite_#{n}", "b", n / 100.0)] }

      chosen = described_class.choose(scored)

      expect(chosen.size).to eq(described_class::TOTAL)
      expect(chosen.map { it["ratio"] }).to eq(scored.map { it["ratio"] }.sort.first(described_class::TOTAL))
    end

    it "keeps the earlier of two pairs with the same ratio" do
      stub_const("#{described_class}::PER_CANDIDATE", 1)

      expect(described_class.choose([pair("original", "a", 0.5), pair("original", "b", 0.5)]).map { it["name"] })
        .to eq(["a"])
    end
  end

  describe ".label" do
    it "numbers each candidate's shared indexes in the searches' order, as chosen" do
      chosen = [pair("rewrite_1", "b", 0.1), pair("original", "a", 0.2), pair("rewrite_1", "c", 0.3)]

      expect(described_class.label(chosen, %w[original rewrite_1]))
        .to eq("original:shared:1" => ["a"], "rewrite_1:shared:1" => ["b"], "rewrite_1:shared:2" => ["c"])
    end
  end

  describe ".pool" do
    it "takes other candidates' ranked indexes once each, less the candidate's own and any non-candidate's" do
      combinations = { "original:top:1" => ["a"], "original:set_aside:1" => ["s"],
                       "rewrite_1:top:1" => ["b"], "rewrite_1:combination" => %w[b c],
                       "rewrite_2:top:1" => ["a"], "rewrite_2:set_aside:1" => ["c"],
                       "rewrite_3:top:1" => ["p"] }
      searches = %w[original rewrite_1 rewrite_2]

      expect(described_class.pool(combinations, "rewrite_2", searches)).to eq(["b"])
      expect(described_class.pool(combinations, "original", searches)).to eq(%w[b c])
    end
  end
end
