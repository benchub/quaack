# frozen_string_literal: true

require "quaack/enclave/store"

# `quaacks selection --run <run ID>` (README 14d): reads minimax and
# result_comparison, needs no connection, and prints only DONE.
RSpec.describe "quaacks selection" do
  let(:quaacks) { LeakCheck::Quaacks.new }

  after { quaacks.remove }

  def survivor(label, slow) = { "label" => label, "slow_blocks" => slow, "total_blocks_sum" => slow, "footprint" => 0 }

  it "stores the top candidates and exclusions, printing only DONE" do
    store = Quaack::Enclave::Store.create(base: quaacks.store_base)
    store.write("minimax", "survivors" => [survivor("rewrite_1:none", 5), survivor("original:top:1", 9)],
                           "verdicts" => { "rewrite_1:none" => {}, "original:top:1" => {} },
                           "discarded_ties" => [], "infinite_sets" => [])
    store.write("result_comparison", "verdicts" => {}, "discarded" => ["rewrite_1"], "partial_count" => 0)

    outcome = quaacks.run("selection", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    result = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base).read("selection")
    expect(result["top"].map { it["label"] }).to eq(["original:top:1"])
    expect(result["excluded"]).to eq("rewrite_1:none" => "result_mismatch")
  end

  # One upstream entry stands in for every step's: Store names the missing
  # one in the rule, and the error line carries nothing else.
  it "refuses a missing upstream entry as missing_ and its name" do
    store = Quaack::Enclave::Store.create(base: quaacks.store_base)
    store.write("result_comparison", "verdicts" => {}, "discarded" => [], "partial_count" => 0)

    outcome = quaacks.run("selection", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"selection","rule":"missing_minimax"}\n), "", 70])
  end
end
