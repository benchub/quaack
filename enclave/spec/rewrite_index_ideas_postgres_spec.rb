# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/burndown"

# DESIGN.md's rewrite-index-ideas, wired: llm-index-ideas, llm-index-refine, and index-rank for each rewrite that
# survived rewrite-test and counterexamples (rewrite_survived_<n>, which 20260926-14 writes)
# and that plan-pruning didn't prune.
RSpec.describe "quaacks rewrite-index-ideas, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }
  let(:sorted) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end
  let(:rewrite_sql) { sorted }

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)
  def done?(outcome) = [outcome.stderr, outcome.status.exitstatus, outcome.stdout] == ["", 0, %({"type":"done"}\n)]
  def error_line(step, rule) = %({"type":"error","step":"#{step}","rule":"#{rule}"}\n)
  def status = JSON.parse(run("status").stdout.lines.first)["entries"]

  # A run with rewrite_1 stored and searched and ranked (plan-pruning), then marked.
  def ready(survived: true, discarded: false)
    prepare
    store.write("schema_subset", schema_subset)
    rewrite = { "sql" => rewrite_sql, "transformation" => "t #{sentinels.text}", "assumptions" => [] }
    run("rewrite-check", stdin: JSON.generate("rewrites" => [rewrite]))
    run("index-search", "--search", "rewrite_1")
    run("index-rank", "--search", "rewrite_1")
    store.write("rewrite_pruned_1", "discarded" => discarded)
    store.write("rewrite_survived_1", "survived" => survived) unless survived.nil?
  end

  def burndown = Quaack::Enclave::Burndown.read(stored)

  it "records the rewrite's index-search burndown under its search, apart from the original's" do
    ready

    stages = burndown["stages"]
    entry = stored.read("index_search_rewrite_1")
    used = entry["results"].count { |r| !r["refusal"] && r["plans"].values.any? { it["used"] } }
    expect(stages.keys).to include("index-from-query", "index-from-plan", "index-dedupe", "index-test")
    expect(%w[index-from-query index-from-plan index-dedupe index-test].map { stages[it].keys })
      .to all(eq(["rewrite_1"]))
    expect(stages["index-test"]["rewrite_1"]).to include("in" => entry["dedupe"]["proposals"].size, "out" => used)
    generated = stages.values_at("index-from-query", "index-from-plan").sum { it["rewrite_1"]["out"] }
    expect(stages["index-dedupe"]["rewrite_1"]["in"]).to eq(generated)
  end

  it "sends a surviving rewrite's payload with its own query and its plan redacted through redact" do
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

  # The rewrite orders by total, which the original query doesn't name, so
  # its payload keeps total's stats too.
  it "sends stats for the columns the original query or the rewrite references" do
    ready

    payload = JSON.parse(run("index-payload", "--search", "rewrite_1").stdout.lines.first)

    expect(payload["stats"]["tables"].first["columns"].map { it["name"] }).to eq(%w[note status total])
  end

  [[{ survived: nil }, "not yet through rewrite-test and counterexamples"],
   [{ survived: false }, "dropped by rewrite-test and counterexamples"],
   [{ discarded: true }, "pruned by plan-pruning"]].each do |marks, why|
    it "refuses the llm-index-ideas and llm-index-refine steps for a rewrite #{why}" do
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

  it "runs llm-index-ideas, llm-index-refine, and a second index-rank for a surviving rewrite, with status progress" do
    ready
    before = status
    pruning = burndown["stages"]

    expect(done?(run("index-test", "--search", "rewrite_1", stdin: JSON.generate("ddls" => [])))).to be(true)
    feedback = run("index-feedback", "--search", "rewrite_1")
    expect([feedback.stderr, feedback.status.exitstatus]).to eq(["", 0])
    expect(done?(run("index-rank", "--search", "rewrite_1"))).to be(true)

    # Task 20261001-20: the second index-rank's record replaces plan-pruning's, and with no LLM idea, says
    # why llm-index-refine didn't run.
    stages = burndown["stages"]
    expect(pruning.keys).not_to include("llm-index-ideas", "llm-index-refine")
    expect(stages["index-rank"]).to eq(pruning["index-rank"])
    expect(stages["index-rank"].keys).to eq(["rewrite_1"])
    expect(stages["llm-index-ideas"]).to eq(
      "rewrite_1" => { "in" => 0, "added" => { "llm" => 0 }, "dropped" => {}, "set_aside" => 0, "out" => 0,
                       "extra" => {} }
    )
    expect(stages["llm-index-refine"]["rewrite_1"]["extra"]).to eq("no_ideas_tested" => 1)

    names = %w[rewrite_index_ideas_1 index_generated_rewrite_1 index_llm_ranked_rewrite_1]
    expect(before.slice(*names)).to eq(names.zip([true, false, false]).to_h)
    expect(status.slice(*names)).to eq(names.zip([true, true, true]).to_h)
  end

  # Task 20261004-76: index-test asks the planner about the rewrite's own query, in both LLM rounds.
  context "when the rewrite filters on an expression the original doesn't" do
    let(:rewrite_sql) do
      "SELECT o.note, o.status FROM public.orders o WHERE lower(o.note) = lower($1) AND o.status = $2"
    end
    let(:for_rewrite) { "CREATE INDEX ON public.orders (lower(note))" }
    let(:for_original) { "CREATE INDEX ON public.orders (note, status)" }

    # The call's exit status, and each line's outcome or type.
    def index_test(ddl, *extra)
      outcome = run("index-test", "--search", "rewrite_1", *extra, stdin: JSON.generate("ddls" => [ddl]))
      [outcome.status.exitstatus, outcome.stdout.lines.map { JSON.parse(it).then { |l| l["outcome"] || l["type"] } }]
    end

    def used_by_ddl(results)
      results.to_h do |result|
        [Quaack::Enclave::IndexStore.candidate(result["candidate"]).to_ddl, result["plans"].values.any? { it["used"] }]
      end
    end

    it "keeps the ideas the rewrite uses, and not the ones only the original would use" do
      ready

      expect([index_test(for_original), index_test(for_rewrite, "--round", "refinement")])
        .to all(eq([0, %w[accepted done]]))

      results = stored.read("index_search_rewrite_1")["llm_results"]
      expect(results.map { it["round"] }).to eq([nil, "refinement"])
      expect(used_by_ddl(results)).to eq(
        "CREATE INDEX ON public.orders USING btree (note, status)" => false,
        "CREATE INDEX ON public.orders USING btree (lower(note))" => true
      )
    end
  end
end
