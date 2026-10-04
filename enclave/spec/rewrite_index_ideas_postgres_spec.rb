# frozen_string_literal: true

require_relative "support/index_search_run"

# DESIGN.md step 11, wired: 5a-5, 5a-6, and 5a-7 for each rewrite that
# survived steps 9 and 10 (rewrite_survived_<n>, which 20260926-14 writes)
# and that step 8 didn't prune.
RSpec.describe "quaacks step 11, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }
  let(:sorted) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)
  def done?(outcome) = [outcome.stderr, outcome.status.exitstatus, outcome.stdout] == ["", 0, %({"type":"done"}\n)]
  def error_line(step, rule) = %({"type":"error","step":"#{step}","rule":"#{rule}"}\n)
  def status = JSON.parse(run("status").stdout.lines.first)["entries"]

  # A run with rewrite_1 stored and searched and ranked (step 8), then marked.
  def ready(survived: true, discarded: false)
    prepare
    store.write("schema_subset", schema_subset)
    rewrite = { "sql" => sorted, "transformation" => "t #{sentinels.text}", "assumptions" => [] }
    run("rewrite-check", stdin: JSON.generate("rewrites" => [rewrite]))
    run("index-search", "--search", "rewrite_1")
    run("index-rank", "--search", "rewrite_1")
    store.write("rewrite_pruned_1", "discarded" => discarded)
    store.write("rewrite_survived_1", "survived" => survived) unless survived.nil?
  end

  it "sends a surviving rewrite's payload with its own query and its plan redacted through 3g" do
    ready

    outcome = run("index-payload", "--search", "rewrite_1")

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    expect_no_leaks(sentinels, outcome)
    payload = JSON.parse(outcome.stdout.lines.first)
    entry = stored.read("index_search_rewrite_1")
    expect(payload["query"]).to eq(stored.read("rewrite_1")["sql"])
    expect(payload["plan"]).to eq(entry["baseline"]["slow"]["plan"].map { it.except("Settings") })
    expect(JSON.generate(payload["plan"])).to include("Sort")
    expect(payload["mechanical_results"]["baseline"])
      .to eq(entry["baseline"].transform_values { it.slice("total_cost", "plan") })
  end

  [[{ survived: nil }, "not yet through steps 9 and 10"], [{ survived: false }, "dropped by steps 9 and 10"],
   [{ discarded: true }, "pruned by step 8"]].each do |marks, why|
    it "refuses the 5a-5 and 5a-6 steps for a rewrite #{why}" do
      ready(**marks)

      expect(run("index-payload", "--search", "rewrite_1").stdout)
        .to eq(error_line("index-payload", "index_payload_unknown_search"))
      expect(run("index-test", "--search", "rewrite_1", stdin: JSON.generate("ddls" => [])).stdout)
        .to eq(error_line("index-test", "index_test_unknown_search"))
      expect(run("index-feedback", "--search", "rewrite_1").stdout)
        .to eq(error_line("index-feedback", "index_feedback_unknown_search"))
      expect(status["rewrite_index_ideas_1"]).to be(false)
    end
  end

  it "runs 5a-5, 5a-6, and a second 5a-7 for a surviving rewrite, and reports its progress in status" do
    ready
    before = status

    expect(done?(run("index-test", "--search", "rewrite_1", stdin: JSON.generate("ddls" => [])))).to be(true)
    feedback = run("index-feedback", "--search", "rewrite_1")
    expect([feedback.stderr, feedback.status.exitstatus]).to eq(["", 0])
    expect(done?(run("index-rank", "--search", "rewrite_1"))).to be(true)

    names = %w[rewrite_index_ideas_1 index_generated_rewrite_1 index_llm_ranked_rewrite_1]
    expect(before.slice(*names)).to eq(names.zip([true, false, false]).to_h)
    expect(status.slice(*names)).to eq(names.zip([true, true, true]).to_h)
  end
end
