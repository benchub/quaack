# frozen_string_literal: true

require_relative "support/index_search_run"

# DESIGN.md's result-comparison: `quaacks result-comparison` runs the original and each measured
# candidate as plain queries per literal set on the racetrack, compares them
# in the enclave, and stores verdicts. Mismatching candidates are discarded.
RSpec.describe "quaacks result-comparison, against a real server" do
  include_context "an index search run"

  def run(step) = quaacks.run(step, "--run", store.run_id, env: libpq_env)

  it "stores a verdict per candidate and literal set, discards a mismatch, and sends only done" do
    prepare
    stored.write("baseline", "timeout_ms" => 5_000)
    stored.write("rewrite_1", "sql" => "SELECT o.note, o.status FROM public.orders o " \
                                       "WHERE o.status = $2 AND o.note = $1")
    stored.write("rewrite_2", "sql" => "SELECT o.note, o.status FROM public.orders o " \
                                       "WHERE o.note = $1 AND o.status <> $2")
    stored.write("rewrite_3", "sql" => "SELECT 1")
    stored.write("candidate_runs", "candidates" => { "rewrite_1" => {}, "rewrite_2" => {} })

    outcome = run("result-comparison")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("result_comparison")
    pass = { "result" => "pass", "rule" => nil }
    expect(entry["verdicts"]["rewrite_1"]).to eq(%w[slow worst_case typical].to_h { [it, pass] })
    expect(entry["verdicts"]["rewrite_2"]["slow"]).to eq("result" => "fail", "rule" => "row_count")
    expect(entry["verdicts"].keys).to eq(%w[rewrite_1 rewrite_2])
    expect(entry["discarded"]).to eq(["rewrite_2"])
    expect(entry["partial_count"]).to eq(0)
  end
end
