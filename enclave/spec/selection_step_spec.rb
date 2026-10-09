# frozen_string_literal: true

require "quaack/enclave/store"
require "quaack/enclave/burndown"

# `quaacks selection --run <run ID>` (DESIGN.md's selection): reads minimax and
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
    differed = { "rewrite_1" => { "slow" => { "result" => "fail", "rule" => "value" } } }
    store.write("result_comparison", "verdicts" => differed,
                                     "discarded" => ["rewrite_1"], "partial_count" => 0)

    outcome = quaacks.run("selection", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([counts_then_done(top: 1, excluded: 1), "", 0])
    result = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base).read("selection")
    expect(result["top"].map { it["label"] }).to eq(["original:top:1"])
    expect(result["excluded"]).to eq("rewrite_1:none" => "result_mismatch")
  end

  describe "measurement's burndown" do
    let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base) }

    def run = quaacks.run("selection", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
    def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

    # rewrite_1 ranks, rewrite_2 differs on production, rewrite_3 timed out
    # in every run, rewrite_4 measured no better, and rewrite_5 was disproved
    # in counterexamples, so it never reached measurement.
    def measured_run
      (1..5).each do |n|
        store.write("rewrite_#{n}", "sql" => "SELECT #{n}")
        store.write("rewrite_survived_#{n}", "survived" => n != 5)
      end
      measure
      store.write("minimax", "survivors" => [survivor("rewrite_1:none", 5), survivor("rewrite_2:none", 4)],
                             "verdicts" => { "rewrite_1:none" => {}, "rewrite_2:none" => {}, "rewrite_4:none" => {} },
                             "discarded_ties" => [], "infinite_sets" => [])
      store.write("result_comparison", "verdicts" => { "rewrite_2" => { "slow" => mismatch } },
                                       "discarded" => ["rewrite_2"], "partial_count" => 2)
    end

    def mismatch = { "result" => "fail", "rule" => "row_count" }

    # candidate-runs, baseline, and index-baseline, 19 runs in all.
    def measure
      store.write("candidate_runs", "candidates" => { "rewrite_1" => {}, "rewrite_2" => {}, "rewrite_4" => {} },
                                    "timed_out" => ["rewrite_3:none"], "timed_out_count" => 1,
                                    "measurement_runs" => 7)
      store.write("baseline", "sets" => {}, "timed_out" => [], "timeout_ms" => 1, "measurement_runs" => 9)
      store.write("index_baseline", "combinations" => {}, "timed_out" => [], "measurement_runs" => 3)
    end

    it "counts the rewrites that reached it, those ranked going on and the rest dropped by fate, once" do
      measured_run

      run
      first = Quaack::Enclave::Burndown.read(stored)
      FileUtils.rm_f(File.join(stored.path, "selection.json"))
      run

      expect(first).to eq(
        "stages" => { "measurement" => { "rewrites" => {
          "in" => 4, "added" => {}, "set_aside" => 0, "out" => 1, "extra" => { "partial_comparisons" => 2 },
          "dropped" => { "production_mismatch" => 1, "measurement_timed_out" => 1, "not_better" => 1 }
        } } },
        "totals" => { "measurement_runs" => 19 }
      )
      expect(Quaack::Enclave::Burndown.read(stored)).to eq(first)
      expect(stored.read("selection")["top"].map { it["label"] }).to eq(["rewrite_1:none"])
    end
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
