# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks index-test` (DESIGN.md's llm-index-ideas and index-test): the LLM's DDL, filtered
# through the stored search's Dedupe and tested on the racetrack, the way
# the jump server runs it, after a real index-search.
RSpec.describe "quaacks index-test, against a real server" do
  include_context "an index search run"

  let(:partial) { "CREATE INDEX ON public.orders (created_at) WHERE status = 'held'" }

  def index_test(stdin, *extra)
    quaacks.run("index-test", "--run", store.run_id, *extra, stdin:, env: libpq_env)
  end

  def ddls(*list) = JSON.generate("ddls" => list)
  def error_line(rule) = %({"type":"error","step":"index-test","rule":"#{rule}"}\n)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def outcome_line(index, outcome, rule = nil)
    { "type" => "index_outcome", "index" => index, "outcome" => outcome, "rule" => rule, "covered_by" => nil,
      "partial_constant_only" => outcome == "accepted" && index == 1 }
  end

  it "sends one index_outcome per DDL, and tests the accepted ones without touching the mechanical results" do
    prepare
    index_search
    mechanical = stored.read("index_search_original")
    duplicate = Quaack::Enclave::IndexStore.candidate(mechanical["results"].first["candidate"]).to_ddl

    outcome = index_test(ddls(partial, "CREATE INDEX ON orders (total)", duplicate,
                              "CREATE INDEX ON public.orders (total) WHERE note = '#{sentinels.text}'"))

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    expect(lines(outcome)).to eq([outcome_line(1, "accepted"), outcome_line(2, "dropped", "unqualified_table"),
                                  outcome_line(3, "dropped", "duplicate"),
                                  outcome_line(4, "dropped", "partial_not_low_cardinality"), { "type" => "done" }])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("index_search_original")
    expect(entry.slice("baseline", "results")).to eq(mechanical.slice("baseline", "results"))
    tested = entry["llm_results"]
    expect(tested.map { Quaack::Enclave::IndexStore.candidate(it["candidate"]).to_ddl })
      .to eq(["CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held'"])
    expect(tested.map { [it["candidate"]["sources"], it["partial_constant_only"], it["refusal"]] })
      .to eq([[["llm"], true, nil]])
    expect(tested.first["plans"].keys).to eq(entry["baseline"].keys)
    expect(tested.first["plans"].values.map(&:keys).uniq).to eq([%w[used total_cost plan]])
    expect(tested.first["size"]).to be_positive
  end

  context "when a literal's type differs from the one Postgres would infer (e2e 020)" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at::date > now()::date - 7"
    end

    it "tests the accepted DDL, preparing with the literal's type" do
      prepare
      index_search

      outcome = index_test(ddls(partial))

      expect([outcome.stdout, outcome.status.exitstatus])
        .to eq([%({"type":"index_outcome","index":1,"outcome":"accepted","rule":null,"covered_by":null,) +
                %("partial_constant_only":true}\n{"type":"done"}\n), 0])
      expect(stored.read("index_search_original")["llm_results"].size).to eq(1)
    end
  end

  it "saves the Dedupe, so the replacement round sees the first round's survivors, and adds its results" do
    prepare
    index_search
    index_test(ddls(partial))

    outcome = index_test(ddls(partial, "CREATE INDEX ON public.orders (total)"))

    expect(lines(outcome).first(2)).to eq([outcome_line(1, "dropped", "duplicate"),
                                           outcome_line(2, "accepted").merge("partial_constant_only" => false)])
    expect(stored.read("index_search_original")["llm_results"].map { it["candidate"]["key"].first["name"] })
      .to eq(%w[created_at total])
  end

  it "tags llm-index-refine revisions with --round refinement, and records the round ran even if nothing survived" do
    prepare
    index_search
    index_test(ddls(partial))

    expect(index_test(ddls("CREATE INDEX ON orders (total)"), "--round", "refinement").status.exitstatus).to eq(0)
    expect(stored.read("index_search_original")["refined"]).to be(true)
    index_test(ddls("CREATE INDEX ON public.orders (total)"), "--round", "refinement")

    expect(stored.read("index_search_original")["llm_results"].map { it["round"] }).to eq([nil, "refinement"])
    expect(index_test(ddls(partial), "--round", "third").stdout).to eq(error_line("index_test_unknown_round"))
  end

  it "refuses stdin that isn't {\"ddls\": [strings]}, and a run with no index search, storing nothing" do
    prepare
    expect(index_test(ddls(partial)).stdout).to eq(error_line("index_test_no_index_search"))

    index_search
    before = stored.read("index_search_original")
    [JSON.generate("ddls" => partial), JSON.generate("ddls" => [1]), JSON.generate("ddls" => [], "x" => 1)]
      .each { expect(index_test(it).stdout).to eq(error_line("index_test_bad_ddls")) }
    expect(index_test(ddls(partial), "--search", "rewrite_1").stdout).to eq(error_line("index_test_unknown_search"))
    expect(stored.read("index_search_original")).to eq(before)
  end
end
