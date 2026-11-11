# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/rewrite_burndown"

# Task 20261010-44: each arrival stage carries what the nearest earlier
# arrival stage on record sent on, falling back past one that wasn't recorded.
RSpec.describe Quaack::Enclave::RewriteBurndown, ".carried" do
  around do |example|
    Dir.mktmpdir("quaack-rewrite-burndown-spec") do |tmp|
      @base = File.join(tmp, "runs")
      example.run
    end
  end

  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  def arrived(stage, inn, added, out)
    Quaack::Enclave::Burndown.record(store, stage, :rewrites, in: inn, added:, out:)
  end

  it "is 0 when no earlier arrival stage is on record" do
    expect(described_class.carried(store, "llm")).to eq(0)
  end

  it "carries rewrite-rules' out into llm-rewrites" do
    arrived("rewrite-rules", 0, { some_rule: 3 }, 3)
    expect(described_class.carried(store, "llm")).to eq(3)
  end

  it "carries the nearest earlier stage's out, not an older one's" do
    arrived("rewrite-rules", 0, { some_rule: 3 }, 3)
    arrived("llm-rewrites", 3, { llm: 4 }, 7)
    expect(described_class.carried(store, "operator")).to eq(7)
  end

  it "falls back past a missing stage to the one before it" do
    arrived("rewrite-rules", 0, { some_rule: 3 }, 3)
    expect(described_class.carried(store, "operator")).to eq(3)
  end

  it "never carries from its own stage or a later one" do
    arrived("operator-rewrites", 0, { operator: 5 }, 5)
    expect(described_class.carried(store, "llm")).to eq(0)
  end
end
