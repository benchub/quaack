# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks index-rank` (README 5a-7): ranks and combines every tested
# candidate of a search, mechanical and LLM, after a real index-search and
# index-test.
RSpec.describe "quaacks index-rank, against a real server" do
  include_context "an index search run"

  def index_rank(*extra) = quaacks.run("index-rank", "--run", store.run_id, *extra, env: libpq_env)
  def error_line(rule) = %({"type":"error","step":"index-rank","rule":"#{rule}"}\n)

  def index_test(*ddls)
    quaacks.run("index-test", "--run", store.run_id, stdin: JSON.generate("ddls" => ddls), env: libpq_env)
  end

  it "stores the top three and the best combination from mechanical and LLM candidates, and sends only done" do
    prepare
    # The sentinel is a literal in the slow and worst-case sets, so a plan
    # stored unredacted carries it, and the leak check below bites.
    expect(stored.read("literal_sets").values_at("slow", "worst_case").map { it.dig("$1", "value") })
      .to eq([sentinels.text] * 2)
    index_search
    index_test("CREATE INDEX ON public.orders (status) WHERE note = 'n1'", # dropped: not low-cardinality
               "CREATE INDEX ON public.orders (note) WHERE status = 'held'")

    outcome = index_rank

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    ranking = stored.read("index_ranking_original")
    entry = stored.read("index_search_original")
    used = (entry["results"] + entry["llm_results"]).select { it["plans"].values.any? { |p| p["used"] } }
    expect(used.size).to be >= 2
    expect(ranking.keys).to eq(%w[top combination])
    expect(ranking["top"].size).to eq([used.size, 3].min)
    expect(ranking["top"].first.keys).to eq(%w[ddl size costs used partial plans])
    worst = ranking["top"].map { |e| e["costs"].values.map { 1 - (it["after"] / it["before"]) }.min }
    expect(worst).to eq(worst.sort.reverse)
    expect(ranking["top"].flat_map { it["ddl"] })
      .to include("CREATE INDEX ON public.orders USING btree (note) WHERE status = 'held'")
    expect(ranking["top"].first["costs"].keys).to eq(entry["baseline"].keys)
    expect(ranking["top"].first["costs"].values.first["before"])
      .to eq(entry["baseline"].values.first["total_cost"])
    kept = ranking["top"] + [ranking["combination"]].compact
    expect(kept.map { it["plans"].keys }).to all(eq(entry["baseline"].keys))
    held = JSON.generate(kept.map { it["plans"] })
    expect(kept.flat_map { it["plans"].values }).to all(be_a(Array))
    expect(LeakCheck.findings(sentinels, stdout: held)).to eq([])
    expect(held).to include("$1")
  end

  context "when a literal's type differs from the one Postgres would infer (e2e 020)" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at::date > now()::date - 7"
    end

    it "ranks, preparing with the literal's type" do
      prepare
      index_search

      outcome = index_rank

      expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
      expect(stored.read("index_ranking_original")["top"]).not_to be_empty
    end
  end

  it "refuses an unknown search, and a run with no index search" do
    prepare

    expect(index_rank.stdout).to eq(error_line("index_rank_no_index_search"))
    expect(index_rank("--search", "rewrite_1").stdout).to eq(error_line("index_rank_unknown_search"))
  end
end
