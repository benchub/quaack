# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/burndown"
require "quaack/enclave/refinement"
require "quaack/enclave/steps/step_counts"

# `quaacks index-rank` (DESIGN.md's index-rank): ranks and combines every tested
# candidate of a search, mechanical and LLM, after a real index-search and
# index-test.
RSpec.describe "quaacks index-rank, against a real server" do
  include_context "an index search run"

  def index_rank(*extra) = quaacks.run("index-rank", "--run", store.run_id, *extra, env: libpq_env)
  def error_line(rule) = %({"type":"error","step":"index-rank","rule":"#{rule}"}\n)

  def index_test(*ddls)
    quaacks.run("index-test", "--run", store.run_id, stdin: JSON.generate("ddls" => ddls), env: libpq_env)
  end

  it "stores the top three and the best combination from mechanical and LLM candidates, sends counts and done" do
    prepare
    # The sentinel is a literal in the slow and worst-case sets, so a plan
    # stored unredacted carries it, and the leak check below bites.
    expect(stored.read("literal_sets").values_at("slow", "worst_case").map { it.dig("$1", "value") })
      .to eq([sentinels.text] * 2)
    index_search
    index_test("CREATE INDEX ON public.orders (status) WHERE note = 'n1'", # dropped: not low-cardinality
               "CREATE INDEX ON public.orders (note) WHERE status = 'held'")

    outcome = index_rank

    ranking = stored.read("index_ranking_original")
    # No combination beats the best single index here, so none combined.
    expect(ranking["combination"]).to be_nil
    expect(ranking["top"].size).to be >= 2
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([counts_then_done(ranked: ranking["top"].size, combined: 0), "", 0])
    expect_no_leaks(sentinels, outcome)
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

  def burndown = Quaack::Enclave::Burndown.read(stored)
  def used?(result) = !result["refusal"] && result["plans"].values.any? { it["used"] }

  # Task 20261001-20: index-rank's record is the latest ranking's, and says what didn't make the cut.
  it "records index-rank in the burndown, the latest ranking replacing an earlier one" do
    prepare
    index_search
    index_test("CREATE INDEX ON public.orders (note) WHERE status = 'held'")
    entry = stored.read("index_search_original")
    used = (entry["results"] + entry["llm_results"]).count { used?(it) }
    before = burndown

    index_rank
    first = burndown
    index_rank

    ranking = stored.read("index_ranking_original")
    record = burndown["stages"]["index-rank"]["original"]
    # Four used candidates: the top three go on, and each of the three
    # combinations with the best one leaves an index unused, so there's no
    # combination.
    expect([used, ranking["top"].size, ranking["combination"]]).to eq([4, 3, nil])
    expect(record).to eq(
      "in" => 4, "added" => { "combinations" => 3 },
      "dropped" => { "below_top_three" => 1, "combination_unused_index" => 3 },
      "set_aside" => 0, "out" => 3, "extra" => {}
    )
    # The LLM's idea held up, so llm-index-refine had nothing to revise.
    expect(burndown["stages"]["llm-index-refine"]).to eq(
      "original" => { "in" => 0, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 0,
                      "extra" => { "nothing_fell_short" => 1 } }
    )
    expect(burndown["stages"].except("index-rank", "llm-index-refine")).to eq(before["stages"])
    expect(burndown["stages"]["index-rank"]).to eq(first["stages"]["index-rank"])
    explains = first["totals"]["hypothetical_explains"] - before["totals"]["hypothetical_explains"]
    expect(explains).to eq((4 + 3) * entry["baseline"].size)
    expect(burndown["totals"]["hypothetical_explains"]).to eq(first["totals"]["hypothetical_explains"] + explains)
  end

  it "records why llm-index-refine didn't run, once llm-index-ideas has, and nothing when it did run" do
    prepare
    index_search
    index_rank
    expect(burndown["stages"].keys).not_to include("llm-index-refine")

    index_test
    index_rank
    expect(burndown["stages"]["llm-index-refine"]).to eq(
      "original" => { "in" => 0, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 0,
                      "extra" => { "no_ideas_tested" => 1 } }
    )
  end

  it "records nothing for llm-index-refine when an idea fell short, so it ran or will" do
    prepare
    index_search
    index_test("CREATE INDEX ON public.orders (total)")
    expect(Quaack::Enclave::Refinement.shortfalls(stored.read("index_search_original"))).to eq([["unused", nil]])

    index_rank
    expect(burndown["stages"].keys).not_to include("llm-index-refine")

    refine = JSON.generate("ddls" => [])
    quaacks.run("index-test", "--run", store.run_id, "--round", "refinement", stdin: refine, env: libpq_env)
    refined = burndown["stages"]["llm-index-refine"]
    index_rank
    expect(burndown["stages"]["llm-index-refine"]).to eq(refined)
    expect(refined["original"]["extra"]).to eq("fell_short" => 1)
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

      expect([outcome.stdout.lines.last, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
      expect(stored.read("index_ranking_original")["top"]).not_to be_empty
    end
  end

  # Task 20261006-24: a self-join where an index on o finds o's few rows and
  # one on p finds each one's partners, so index-search's mechanical
  # candidates combine to beat any single one, and step_counts counts the
  # combination's indexes.
  context "when a combination of indexes beats the best single one" do
    let(:query) do
      "SELECT o.id, p.id FROM public.orders o JOIN public.orders p ON p.total = o.total " \
        "WHERE o.note = '#{sentinels.text}' AND p.status = 'held'"
    end

    it "stores the combination and counts its indexes as combined" do
      prepare
      index_search

      outcome = index_rank

      ranking = stored.read("index_ranking_original")
      expect(ranking["combination"]["ddl"])
        .to contain_exactly(*["(note, total)", "(total, status)", "(status)"]
                               .map { "CREATE INDEX ON public.orders USING btree #{it}" })
      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([counts_then_done(ranked: ranking["top"].size, combined: 3), "", 0])
      expect_no_leaks(sentinels, outcome)
    end
  end

  it "refuses an unknown search, and a run with no index search" do
    prepare

    expect(index_rank.stdout).to eq(error_line("index_rank_no_index_search"))
    expect(index_rank("--search", "rewrite_1").stdout).to eq(error_line("index_rank_unknown_search"))
  end
end

# Task 20261004-1: index-rank's step_counts, from its ranking.
RSpec.describe Quaack::Enclave::Steps::StepCounts, ".index_rank" do
  it "counts the top single indexes, and the indexes in the best combination" do
    ranking = { "top" => [{ "ddl" => ["a"] }, { "ddl" => ["b"] }], "combination" => { "ddl" => %w[a b c] } }

    expect(described_class.index_rank(ranking)).to eq(type: :step_counts, ranked: 2, combined: 3)
    expect(described_class.index_rank(ranking.merge("combination" => nil)))
      .to eq(type: :step_counts, ranked: 2, combined: 0)
  end
end
