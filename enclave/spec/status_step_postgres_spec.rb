# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks status`: which step outputs a run's store holds, so `quaack run`
# can resume.
RSpec.describe "quaacks status, against a real server" do
  include_context "an index search run"

  # The output each step from 2 to racetrack-setup stores last, in the order
  # `quaack setup` runs them.
  setup = %w[inventory run_server qualified_query schema_subset statistics volatility classification redacted_plan
             literal_sets clock_replacements racetrack_setup]

  def status = JSON.parse(quaacks.run("status", "--run", store.run_id).stdout.lines.first)

  # The status message, without the inventory to racetrack-setup entries, which prepare
  # writes some of.
  define_method(:later) { status.then { it.merge("entries" => it["entries"].except(*setup)) } }

  def index_test(stdin, *extra)
    quaacks.run("index-test", "--run", store.run_id, *extra, stdin:, env: libpq_env)
  end

  it "says which index-search outputs are in the store, with llm-index-ideas done only after first-round index-test" do
    prepare
    expect(later).to eq("type" => "status", "entries" => {
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
    expect(later["entries"].select { _2 }.keys).to eq(["index_search_original"])

    index_test(JSON.generate("ddls" => []))
    quaacks.run("index-rank", "--run", store.run_id, env: libpq_env)
    expect(later["entries"].values).to eq([true, true, true] + ([false] * 11))
  end

  it "says whether each inventory to racetrack-setup output is in the store, so quaack setup can resume" do
    expect(status["entries"].slice(*setup)).to eq(setup.to_h { [it, false] })

    setup.first(4).each { store.write(it, true) }
    expect(status["entries"].slice(*setup).select { _2 }.keys).to eq(setup.first(4))

    setup.each { store.write(it, true) }
    expect(status["entries"].slice(*setup)).to eq(setup.to_h { [it, true] })
  end

  it "says whether index_build is in the store" do
    prepare
    store.write("index_build", "indexes" => {}, "combinations" => {})
    expect(status["entries"]["index_build"]).to be(true)
  end

  it "says whether each arena-setup and index-build to result-comparison output is in the store" do
    prepare
    names = %w[arena_setup baseline index_baseline candidate_runs minimax result_comparison]
    names.each { store.write(it, true) }
    expect(later["entries"].select { _2 }.keys).to eq(names)
  end

  it "says whether selection is in the store, for the report" do
    prepare
    store.write("selection", "top" => [], "excluded" => {}, "infinite_sets" => [])
    expect(status["entries"]["selection"]).to be(true)
  end
end
