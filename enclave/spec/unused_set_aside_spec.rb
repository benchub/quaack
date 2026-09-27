# frozen_string_literal: true

require "quaack/enclave/unused_set_aside"
require "quaack/enclave/single_candidate_test"
require "quaack/enclave/index_candidate"
require "quaack/enclave/table_name"

# 20260927-11: which of 5a-4's results 12a builds for real anyway.
RSpec.describe Quaack::Enclave::UnusedSetAside do
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:low) { [[orders, "status"]] }
  let(:sct) { Quaack::Enclave::SingleCandidateTest }

  def candidate(key, **rest) = Quaack::Enclave::IndexCandidate.new(table: orders, key:, sources: [:parse], **rest)

  def result(candidate, used: false, refusal: nil)
    plans = refusal ? {} : { "slow" => sct::Plan.new(used:, total_cost: 1.0, canonical_plan: nil, raw_plan: nil) }
    sct::Result.new(candidate:, size: refusal ? nil : 8192, plans:, refusal:)
  end

  def select(*results) = described_class.select(sct::Report.new(baseline: nil, results:), low)

  it "sets aside an unused key-only B-tree led by a low-cardinality column" do
    status = candidate(%w[status total])
    expect(select(result(status))).to eq([status])
  end

  it "doesn't set aside one led by a column that isn't low-cardinality" do
    expect(select(result(candidate(%w[total status])))).to eq([])
  end

  it "doesn't set aside one with INCLUDE columns" do
    expect(select(result(candidate(["status"], include: ["total"])))).to eq([])
  end

  it "doesn't set aside one the planner used" do
    expect(select(result(candidate(%w[status total]), used: true))).to eq([])
  end

  it "doesn't set aside a refused one" do
    refusal = sct::Refusal.new(:hypopg_refused, "42703")
    expect(select(result(candidate(%w[status total]), refusal:))).to eq([])
  end
end
