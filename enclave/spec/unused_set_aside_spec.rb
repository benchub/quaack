# frozen_string_literal: true

require "quaack/enclave/unused_set_aside"
require "quaack/enclave/single_candidate_test"
require "quaack/enclave/index_candidate"
require "quaack/enclave/table_name"

# 20260927-11: which of index-test's results index-build builds for real anyway.
RSpec.describe Quaack::Enclave::UnusedSetAside do
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:low) { [[orders, "status"]] }
  let(:sct) { Quaack::Enclave::SingleCandidateTest }

  let(:users) { Quaack::Enclave::TableName.new(schema: "public", name: "users") }

  def candidate(key, table: orders, **rest) = Quaack::Enclave::IndexCandidate.new(table:, key:, sources: [:parse], **rest)

  def result(candidate, used: false, refusal: nil)
    plans = refusal ? {} : { "slow" => sct::Plan.new(used:, total_cost: 1.0, canonical_plan: nil, raw_plan: nil) }
    sct::Result.new(candidate:, size: refusal ? nil : 8192, plans:, refusal:, literal_sets: {})
  end

  def select(*results, low_cardinality: low) = described_class.select(sct::Report.new(baseline: nil, results:), low_cardinality)

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

  # 20260927-19: each one is a real build, so a search sets aside at most
  # MAX_PER_SEARCH, the first in index-test's order.
  it "sets aside at most MAX_PER_SEARCH per search, the first ones" do
    keys = [%w[status total], %w[status region], %w[status id], %w[status total region]]
    candidates = keys.map { candidate(it) }
    expect(described_class::MAX_PER_SEARCH).to eq(2)
    expect(select(*candidates.map { result(it) })).to eq(candidates.first(2))
  end

  # 20261008-77: one per table first, in report order, so the first table
  # can't starve the second; then the leftover slots, in report order.
  it "spreads MAX_PER_SEARCH across tables before taking a second from one" do
    first, second = [%w[status total], %w[status region]].map { candidate(it) }
    other = candidate(%w[kind id], table: users)
    picked = select(*[first, second, other].map { result(it) }, low_cardinality: low + [[users, "kind"]])
    expect(picked).to eq([first, other])
  end
end
