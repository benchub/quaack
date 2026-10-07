# frozen_string_literal: true

require "quaack/protocol/step_counts"
require "quaack/protocol/whitelist"

# The one check on a step_counts message's fields, for the enclave's egress
# function and the driver both: small counts under fixed names, and the
# names of rewrite-rules' rules that fired, from the shared list.
RSpec.describe Quaack::Protocol::StepCounts do
  let(:sentinel) { "SENTINEL_STEP_COUNT_7d2a" }

  def valid?(fields) = described_class.valid?(fields)

  it "lists the count names and QUAACK's rule names, as frozen Strings" do
    expect(described_class::COUNTS).to include("found", "used", "timed_out")
    expect(described_class::RULE_NAMES).to include("key_in_self_join", "or_to_union")
    [described_class::COUNTS, described_class::RULE_NAMES].each { expect(it).to be_frozen.and(all(be_frozen)) }
  end

  it "is whitelisted with exactly the count names and rules" do
    expect(Quaack::Protocol::WHITELIST[:step_counts].map(&:name))
      .to match_array(described_class::COUNTS + ["rules"])
  end

  it "takes counts under the fixed names, and fired rules by name" do
    expect(valid?({ "found" => 12, "used" => 0 })).to be(true)
    expect(valid?({ "rules" => %w[key_in_self_join or_to_union] })).to be(true)
    expect(valid?({})).to be(true)
  end

  it "refuses a count name that isn't one of them, such as a planted sentinel" do
    expect(valid?({ sentinel => 1 })).to be(false)
    expect(valid?({ found: 1 })).to be(false)
  end

  it "refuses a count that isn't an Integer from zero up, such as a planted sentinel" do
    [sentinel, "3", 3.0, -1, nil, true, [3], { "a" => 3 }, 10**12].each do |bad|
      expect(valid?({ "found" => bad })).to be(false), bad.inspect
    end
  end

  it "refuses a rule name not on the list, such as a planted sentinel, or rules that aren't an Array" do
    expect(valid?({ "rules" => ["key_in_self_join", sentinel] })).to be(false)
    expect(valid?({ "rules" => [:key_in_self_join] })).to be(false)
    expect(valid?({ "rules" => %w[or_to_union or_to_union] })).to be(false)
    [sentinel, "or_to_union", nil, 3, { "or_to_union" => 1 }].each do |bad|
      expect(valid?({ "rules" => bad })).to be(false), bad.inspect
    end
  end

  it "refuses fields that aren't a Hash" do
    [nil, [], "found", [["found", 1]]].each { expect(valid?(it)).to be(false), it.inspect }
  end
end
