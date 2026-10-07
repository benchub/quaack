# frozen_string_literal: true

require "quaack/enclave/burndown"
require "quaack/enclave/steps/rewrite_prune"
require_relative "support/index_search_run"

# DESIGN.md's plan-pruning, wired: index-search and index-rank for a rewrite search,
# rewrite-prune against the original's top three, and the plan-pruning burndown.
RSpec.describe "quaacks plan-pruning, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }
  let(:same) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1" }
  let(:sorted) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)

  # Its step_counts line, for a step that sends one, aside.
  def done?(outcome)
    lines = outcome.stdout.lines.reject { it.start_with?(%({"type":"step_counts",)) }
    [outcome.stderr, outcome.status.exitstatus, lines] == ["", 0, [%({"type":"done"}\n)]]
  end

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

  describe "the burndown of llm-rewrites' and operator-rewrites' rewrite-check" do
    let(:not_null_note) { { "kind" => "not_null", "table" => "public.orders", "column" => "note" } }
    let(:bad_placeholder) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $3" }
    let(:llm) do
      [bad_placeholder, same, rewrite(sorted).merge("assumptions" => [not_null_note]),
       "SELECT o.note, o.status FROM public.orders o WHERE o.nosuch = $1",
       "SELECT o.note FROM public.orders o WHERE o.note = $1", sorted]
    end

    def stages = Quaack::Enclave::Burndown.read(stored)["stages"]

    def counted(**counts)
      { "in" => 0, "added" => {}, "dropped" => {}, "set_aside" => 0, "extra" => {} }
        .merge(counts.transform_keys(&:to_s))
    end

    def operator(*list) = run("rewrite-check", stdin: JSON.generate("rewrites" => list, "inferred" => true))

    it "drops each rewrite in one stage: refused on arrival by rule, an unmet assumption, or plan-pruning's own" do
      ready(*llm)

      expect(stages["llm-rewrites"]).to eq(
        "rewrites" => counted(added: { "llm" => 6 }, dropped: { "bad_placeholder" => 1, "too_many" => 1 }, out: 4)
      )
      expect(stages["assumption-check"])
        .to eq("rewrites" => counted(in: 4, dropped: { "unmet_assumption" => 1 }, out: 3))
      expect(stages["plan-pruning"])
        .to eq("rewrites" => counted(in: 2, dropped: { "failed_to_plan" => 1, "output_mismatch" => 1 }, out: 0))
      expect(stages).not_to have_key("operator-rewrites")
    end

    it "counts the operator's rewrites apart from the LLM's, with their warnings in assumption-check" do
      ready(same)

      operator(rewrite(same).merge("assumptions" => [{ "kind" => "sorted" }]),
               rewrite(sorted).merge("assumptions" => [not_null_note]), rewrite(bad_placeholder))

      expect(stages["operator-rewrites"]).to eq(
        "rewrites" => counted(added: { "operator" => 3 }, dropped: { "bad_assumption" => 1, "bad_placeholder" => 1 },
                              out: 1)
      )
      expect(stages["llm-rewrites"]["rewrites"]).to include("added" => { "llm" => 1 }, "out" => 1)
      expect(stages["assumption-check"]["rewrites"])
        .to eq(counted(in: 2, dropped: { "unmet_assumption" => 0 }, out: 2, extra: { "operator_warnings" => 1 }))
      # Neither call's rewrites failed plan-pruning's checks, so neither writes it a record.
      expect(stages).not_to have_key("plan-pruning")
    end

    it "counts nothing twice when a call that died before its marker is run again" do
      ready(*llm)
      first = Quaack::Enclave::Burndown.read(stored)

      check(*llm)

      expect(Quaack::Enclave::Burndown.read(stored)).to eq(first)
    end
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
    expect(Quaack::Enclave::Burndown.read(stored)["stages"]["plan-pruning"].except("rewrites")).to eq(
      "rewrite_1" => { "in" => 1, "added" => {}, "dropped" => { "same_plans" => 1 }, "set_aside" => 0, "out" => 0,
                       "extra" => {} },
      "rewrite_2" => { "in" => 1, "added" => {}, "dropped" => { "same_plans" => 0 }, "set_aside" => 0, "out" => 1,
                       "extra" => {} }
    )
  end

  it "counts each rewrite once in plan-pruning, its own drops and the prune's, though rewrite-prune is run again" do
    ready(same, sorted, "SELECT o.note FROM public.orders o WHERE o.note = $1")
    %w[original rewrite_1 rewrite_2].each { search_and_rank(it) }
    run("rewrite-prune", "--search", "rewrite_1")
    2.times { run("rewrite-prune", "--search", "rewrite_2") }

    searches = Quaack::Enclave::Burndown.read(stored)["stages"]["plan-pruning"].values
    total = %w[in out].to_h { |field| [field, searches.sum { it[field] }] }
    expect(total).to eq("in" => 3, "out" => 1)
    expect(searches.map { it["dropped"] }.reduce { |a, b| a.merge(b) { |_, x, y| x + y } })
      .to eq("output_mismatch" => 1, "same_plans" => 1)
  end

  # Task 20261004-69: a call that died after its burndown record and before
  # rewrite_pruned_<n> is run again, and this time the rewrite plans
  # differently (here, rewrite_1's entries become rewrite_2's).
  it "keeps the latest outcome's record when a call that died before its entry is run again" do
    ready(same, sorted)
    %w[original rewrite_1 rewrite_2].each { search_and_rank(it) }
    run("rewrite-prune", "--search", "rewrite_1")
    FileUtils.rm_f(File.join(stored.path, "rewrite_pruned_1.json"))
    %w[rewrite_%s index_search_rewrite_%s index_ranking_rewrite_%s].each do |name|
      store.write(format(name, 1), stored.read(format(name, 2)))
    end

    run("rewrite-prune", "--search", "rewrite_1")

    expect(stored.read("rewrite_pruned_1")).to eq("discarded" => false)
    expect(Quaack::Enclave::Burndown.read(stored)["stages"]["plan-pruning"]["rewrite_1"])
      .to include("in" => 1, "dropped" => { "same_plans" => 0 }, "out" => 1)
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

  it "reports each stored rewrite's plan-pruning progress in status" do
    ready(same)
    search_and_rank("rewrite_1")

    entries = JSON.parse(run("status").stdout.lines.first)["entries"]

    expect(entries.slice("rewrites_generated", "rewrite_1", "index_search_rewrite_1", "index_ranking_rewrite_1",
                         "rewrite_pruned_1", "rewrite_2"))
      .to eq("rewrites_generated" => true, "rewrite_1" => true, "index_search_rewrite_1" => true,
             "index_ranking_rewrite_1" => true, "rewrite_pruned_1" => false)
  end
end
