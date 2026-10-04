# frozen_string_literal: true

require "quaack/enclave/refinement"

# DESIGN.md's llm-index-refine: which of the LLM's candidates fell short in index-test, as the
# decision in 20260922-34 defines it.
RSpec.describe Quaack::Enclave::Refinement do
  def column(name) = { "name" => name, "expression" => nil }

  def result(key:, include: [], size: 8192, costs: { "slow" => 10.0, "fast" => 5.0 }, used: true)
    plans = costs.transform_values { { "used" => used, "total_cost" => it, "plan" => [] } }
    { "candidate" => { "key" => key.map { column(it) }, "include" => include }, "size" => size,
      "refusal" => nil, "plans" => plans }
  end

  def refused(key) = result(key:).merge("refusal" => { "rule" => "hypopg_refused" }, "plans" => {})

  def shortfalls(mechanical, llm) = described_class.shortfalls("results" => mechanical, "llm_results" => llm)

  it "marks an LLM candidate the planner never used, or one HypoPG refused, as unused" do
    unused = result(key: %w[a], used: false)
    refused = refused(%w[b])

    expect(shortfalls([], [unused, refused])).to eq([["unused", nil], ["unused", nil]])
  end

  it "marks one beaten by a mechanical candidate with fewer columns and no higher worst-case cost" do
    llm = result(key: %w[a b], include: %w[c], costs: { "slow" => 10.0, "fast" => 5.0 })
    tie = result(key: %w[a], costs: { "slow" => 10.0, "fast" => 1.0 })
    worse = result(key: %w[a], costs: { "slow" => 10.5, "fast" => 1.0 })

    expect(shortfalls([worse, tie], [llm])).to eq([["beaten", 1]])
    expect(shortfalls([worse], [llm])).to eq([nil])
  end

  it "breaks a column-count tie by smaller size, and never counts a bigger or wider mechanical one as simpler" do
    llm = result(key: %w[a b], size: 16_384)
    smaller = result(key: %w[x], include: %w[y], size: 8192)
    bigger = result(key: %w[x y], size: 32_768)
    wider = result(key: %w[x y z], size: 1)

    expect(shortfalls([bigger, wider, smaller], [llm])).to eq([["beaten", 2]])
    expect(shortfalls([bigger, wider], [llm])).to eq([nil])
  end

  it "ignores a refused or unused mechanical candidate, and the LLM's own revisions" do
    llm = result(key: %w[a b])
    refused = refused(%w[a])
    unused = result(key: %w[a], used: false)
    revision = result(key: %w[z], used: false).merge("round" => "refinement")

    expect(shortfalls([refused, unused], [llm, revision])).to eq([nil])
  end
end
