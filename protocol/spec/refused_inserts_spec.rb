# frozen_string_literal: true

require "quaack/protocol/refused_inserts"

# Task 20261012-12: the one check on a counterexample_round's refused, for
# the enclave's egress function: each refused insert's index, its rule, and,
# for not_immutable, the name of the function that got it refused.
RSpec.describe Quaack::Protocol::RefusedInserts do
  def valid?(value) = described_class.valid?(value)

  it "passes an empty list, an index and a rule, and a not_immutable refusal's function" do
    expect(valid?([])).to be(true)
    expect(valid?([{ index: 0, rule: "insert_select" }])).to be(true)
    expect(valid?([{ "index" => 2, "rule" => "not_immutable", "function" => "pg_catalog.timezone" }])).to be(true)
  end

  [
    ["a sentinel as a function", [{ index: 0, rule: "not_immutable", function: "QSENTINEL7741" }]],
    ["a function with no schema", [{ index: 0, rule: "not_immutable", function: "timezone" }]],
    ["a quoted function name", [{ index: 0, rule: "not_immutable", function: '"s"."my fn"' }]],
    ["a function on another rule", [{ index: 0, rule: "not_plain_value", function: "pg_catalog.concat" }]],
    ["a function that isn't a String", [{ index: 0, rule: "not_immutable", function: 7 }]],
    ["another key", [{ index: 0, rule: "insert_select", detail: "SENTINEL" }]],
    ["a key given twice", [{ index: 0, "index" => 1, rule: "insert_select" }]],
    ["a rule that isn't a word", [{ index: 0, rule: "a value 'SENTINEL'" }]],
    ["a negative index", [{ index: -1, rule: "insert_select" }]],
    ["an index that isn't an Integer", [{ index: "0", rule: "insert_select" }]],
    ["a missing rule", [{ index: 0 }]],
    ["an entry that isn't a Hash", ["insert_select"]],
    ["nil", nil]
  ].each do |what, value|
    it "refuses #{what}" do
      expect(valid?(value)).to be(false)
    end
  end
end
