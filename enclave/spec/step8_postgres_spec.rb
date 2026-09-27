# frozen_string_literal: true

require "quaack/enclave/burndown"
require "quaack/enclave/steps/rewrite_prune"
require_relative "support/index_search_run"

# README step 8, wired: index-search and index-rank for a rewrite search,
# rewrite-prune against the original's top three, and the step 8 burndown.
RSpec.describe "quaacks step 8, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }
  let(:same) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1" }
  let(:sorted) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)
  def done?(outcome) = [outcome.stderr, outcome.status.exitstatus, outcome.stdout] == ["", 0, %({"type":"done"}\n)]

  def rewrite(sql) = { "sql" => sql, "transformation" => "t #{sentinels.text}", "assumptions" => [] }

  def check(*sqls)
    list = sqls.map { it.is_a?(Hash) ? it : rewrite(it) }
    run("rewrite-check", stdin: JSON.generate("rewrites" => list))
  end

  def ready(*sqls)
    prepare
    store.write("schema_subset", schema_subset)
    check(*sqls) unless sqls.empty?
  end

  def search_and_rank(search)
    run("index-search", "--search", search)
    run("index-rank", "--search", search)
  end

  it "records the step 8 burndown with the inbound check's rejections, not 6a's or 6b's" do
    bad_assumption = rewrite(same).merge("assumptions" => [{ "kind" => "sorted" }])
    ready("SELECT o.note, o.status FROM public.orders o WHERE o.note = $3", same,
          "SELECT o.note FROM public.orders o WHERE o.note = $1", bad_assumption)
    check("SELECT o.note, o.status FROM public.orders o WHERE o.nosuch = $1")

    expect(Quaack::Enclave::Burndown.read(stored)["stages"]["step8"]["rewrites"])
      .to include("in" => 4, "out" => 1,
                  "dropped" => { "inbound_check" => 1, "failed_to_plan" => 1, "output_mismatch" => 1 })
  end

  it "searches a stored rewrite with index-search --search rewrite_<n>, sending only DONE" do
    ready(sorted)

    outcome = run("index-search", "--search", "rewrite_1")

    expect(done?(outcome)).to be(true)
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("index_search_rewrite_1")
    expect(JSON.generate(entry["baseline"]["slow"]["plan"])).to include("Sort")
    expect(stored.entry?("index_search_original")).to be(false)
  end

  it "refuses a rewrite search with no stored rewrite" do
    ready

    expect(run("index-search", "--search", "rewrite_1").stdout)
      .to eq(%({"type":"error","step":"index-search","rule":"index_search_unknown_search"}\n))
  end

  it "ranks a rewrite search against the rewrite, not the original" do
    ready(sorted)
    run("index-search", "--search", "rewrite_1")

    expect(done?(run("index-rank", "--search", "rewrite_1"))).to be(true)
    ranking = stored.read("index_ranking_rewrite_1")
    baseline = stored.read("index_search_rewrite_1")["baseline"]["slow"]["total_cost"]
    expect(ranking["top"]).not_to be_empty
    expect(ranking["top"].first["costs"]["slow"]["before"]).to eq(baseline)
  end

  it "prunes a rewrite whose plans match the original's in all three configurations, and keeps one that differs" do
    ready(same, sorted)
    %w[original rewrite_1 rewrite_2].each { search_and_rank(it) }

    first = run("rewrite-prune", "--search", "rewrite_1")
    second = run("rewrite-prune", "--search", "rewrite_2")

    expect([done?(first), done?(second)]).to eq([true, true])
    expect_no_leaks(sentinels, first)
    expect(stored.read("rewrite_pruned_1")).to eq("discarded" => true)
    expect(stored.read("rewrite_pruned_2")).to eq("discarded" => false)
    # The top three it planned with are the rankings' own, rebuilt as candidates.
    %w[original rewrite_2].each do |search|
      ranked = stored.read("index_ranking_#{search}")["top"].flat_map { it["ddl"] }
      expect(ranked).not_to be_empty
      expect(Quaack::Enclave::Steps::RewritePrune.top(stored, search).map(&:to_ddl)).to eq(ranked)
    end
    expect(Quaack::Enclave::Burndown.read(stored)["stages"]["step8"]["pruning"])
      .to include("in" => 2, "out" => 1, "dropped" => { "same_plans" => 1 })
  end

  context "when a literal's type differs from the one Postgres would infer (e2e 020)" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at::date > now()::date - 7"
    end
    let(:swapped) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.created_at::date > now()::date - $2 AND o.note = $1"
    end

    it "checks, searches, ranks, and prunes a rewrite, preparing with the literals' types" do
      ready(swapped)
      expect(stored.entry?("rewrite_1")).to be(true)
      %w[original rewrite_1].each { search_and_rank(it) }

      expect(done?(run("rewrite-prune", "--search", "rewrite_1"))).to be(true)
      expect(stored.read("rewrite_pruned_1")).to eq("discarded" => true)
    end
  end

  it "refuses to prune before both rankings exist" do
    ready(same)
    search_and_rank("rewrite_1")

    expect(run("rewrite-prune", "--search", "rewrite_1").stdout)
      .to eq(%({"type":"error","step":"rewrite-prune","rule":"rewrite_prune_no_ranking"}\n))
  end

  it "reports each stored rewrite's step 8 progress in status" do
    ready(same)
    search_and_rank("rewrite_1")

    entries = JSON.parse(run("status").stdout.lines.first)["entries"]

    expect(entries.slice("rewrites_generated", "rewrite_1", "index_search_rewrite_1", "index_ranking_rewrite_1",
                         "rewrite_pruned_1", "rewrite_2"))
      .to eq("rewrites_generated" => true, "rewrite_1" => true, "index_search_rewrite_1" => true,
             "index_ranking_rewrite_1" => true, "rewrite_pruned_1" => false)
  end
end
