# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks status`: which step outputs a run's store holds, so `quaack run`
# can resume.
RSpec.describe "quaacks status, against a real server" do
  include_context "an index search run"

  def status = JSON.parse(quaacks.run("status", "--run", store.run_id).stdout.lines.first)

  def index_test(stdin, *extra)
    quaacks.run("index-test", "--run", store.run_id, *extra, stdin:, env: libpq_env)
  end

  it "says which step 5 outputs are in the store, with 5a-5 done only after a first-round index-test" do
    prepare
    expect(status).to eq("type" => "status", "entries" => {
                           "index_search_original" => false, "index_generated_original" => false,
                           "index_ranking_original" => false, "rewrite_rules_applied" => false,
                           "rewrites_generated" => false,
                           "operator_rewrites_checked" => false, "arena_setup" => false,
                           "index_build" => false, "baseline" => false, "index_baseline" => false,
                           "candidate_runs" => false, "minimax" => false, "result_comparison" => false,
                           "selection" => false
                         })

    index_search
    index_test(JSON.generate("ddls" => []), "--round", "refinement")
    expect(status["entries"].select { _2 }.keys).to eq(["index_search_original"])

    index_test(JSON.generate("ddls" => []))
    quaacks.run("index-rank", "--run", store.run_id, env: libpq_env)
    expect(status["entries"].values).to eq([true, true, true] + ([false] * 11))
  end

  it "says whether index_build is in the store" do
    prepare
    store.write("index_build", "indexes" => {}, "combinations" => {})
    expect(status["entries"]["index_build"]).to be(true)
  end

  it "says whether each step 4b and 12a to 14c output is in the store" do
    prepare
    names = %w[arena_setup baseline index_baseline candidate_runs minimax result_comparison]
    names.each { store.write(it, true) }
    expect(status["entries"].select { _2 }.keys).to eq(names)
  end

  it "says whether selection is in the store, for the step 15 report" do
    prepare
    store.write("selection", "top" => [], "excluded" => {}, "infinite_sets" => [])
    expect(status["entries"]["selection"]).to be(true)
  end
end
