# frozen_string_literal: true

require "json"
require "quaack/enclave/fuzz/signature"

# A fuzz trial's coverage signature (task 20261012-2): per plan node, its
# position and type, its actual rows as 0, 1, or many, and whether a filter
# removed rows, and whether each query errored. Never a literal.
RSpec.describe Quaack::Enclave::Fuzz::Signature do
  def explain(plan) = JSON.generate([{ "Plan" => plan }])

  let(:sentinel) { "SENTINEL_9f3c" }
  let(:plan) do
    { "Node Type" => "Hash Join", "Actual Rows" => 3, "Actual Loops" => 1,
      "Hash Cond" => "(o.customer_id = c.id)", "Join Filter" => "(o.note <> '#{sentinel}')",
      "Rows Removed by Join Filter" => 0,
      "Plans" => [{ "Node Type" => "Seq Scan", "Relation Name" => "orders", "Actual Rows" => 0.5,
                    "Actual Loops" => 2, "Filter" => "(o.status = '#{sentinel}')", "Rows Removed by Filter" => 4 },
                  { "Node Type" => "Hash", "Actual Rows" => 0, "Actual Loops" => 1,
                    "Plans" => [{ "Node Type" => "Seq Scan", "Relation Name" => "customers", "Actual Rows" => 0,
                                  "Actual Loops" => 0 }] }] }
  end

  it "gives each node, depth first, its type, its rows over all loops as 0, 1 or many, and whether a filter " \
     "removed any" do
    expect(described_class.plan(explain(plan))).to eq(
      [["Hash Join", :many, false], ["Seq Scan", 1, true], ["Hash", 0, false], ["Seq Scan", 0, false]]
    )
  end

  it "counts a node's rows over all its loops, not per loop" do
    inner = { "Node Type" => "Index Scan", "Actual Rows" => 1, "Actual Loops" => 3 }
    expect(described_class.plan(explain(inner))).to eq([["Index Scan", :many, false]])
  end

  it "says a query that errored is :error" do
    expect(described_class.plan(nil)).to eq(:error)
  end

  it "pairs the original's and the candidate's" do
    expect(described_class.trial(explain(plan), nil)).to eq(
      [described_class.plan(explain(plan)), :error]
    )
  end

  it "tells apart plans that differ only in rows or in a filter's work" do
    other = plan.merge("Plans" => [plan["Plans"][0].merge("Rows Removed by Filter" => 0), plan["Plans"][1]])
    expect(described_class.plan(explain(other))).not_to eq(described_class.plan(explain(plan)))
    fewer = plan.merge("Actual Rows" => 1)
    expect(described_class.plan(explain(fewer))).not_to eq(described_class.plan(explain(plan)))
  end

  it "keeps no text from the plan but node types, so no literal is in it" do
    expect(described_class.trial(explain(plan), explain(plan)).flatten.join(" ")).not_to include(sentinel)
    expect(described_class.trial(explain(plan), explain(plan)).flatten.grep(String).uniq)
      .to contain_exactly("Hash Join", "Seq Scan", "Hash")
  end
end
