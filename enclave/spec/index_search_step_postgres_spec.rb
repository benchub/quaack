# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/burndown"
require "quaack/enclave/generator_one"
require "quaack/enclave/steps/step_counts"

# `quaacks index-search` (DESIGN.md's index-search and index-from-query to index-test) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler.
RSpec.describe "quaacks index-search, against a real server" do
  include_context "an index search run"

  def error_line(rule) = %({"type":"error","step":"index-search","rule":"#{rule}"}\n)

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("index_search_original")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  def sources(candidate) = candidate.sources.map(&:to_s).sort

  # The costs a direct EXPLAIN gives for each literal set, bound in $n
  # order, with ddl as the only hypothetical index (or none).
  def direct_costs(ddl)
    conn = production.connect
    conn.exec("SET plan_cache_mode = force_custom_plan")
    conn.exec("SELECT hypopg_create_index(#{conn.escape_literal(ddl)})") if ddl
    conn.prepare("q", stored.read("anchored_query"))
    stored.read("literal_sets").except("fallbacks").transform_values { explain_cost(conn, it) }
  ensure
    conn&.close
  end

  def explain_cost(conn, map)
    values = map.keys.sort_by { Integer(it.delete_prefix("$")) }.map { conn.escape_literal(map[it]["value"]) }
    JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) EXECUTE q(#{values.join(", ")})").getvalue(0,
                                                                                           0))[0]["Plan"]["Total Cost"]
  end

  # Makes the statistics name a column the table doesn't have, so generator
  # one INCLUDEs it for SELECT o.* and HypoPG refuses those candidates.
  def add_ghost_column
    statistics = stored.read("statistics")
    statistics["tables"][0]["column_names"] << "ghost"
    stored.write("statistics", statistics)
  end

  def restored_search(entry)
    Quaack::Enclave::IndexStore.dedupe(
      entry["dedupe"], statistics: Quaack::Enclave::PlannerStatistics.load(stored).statistics,
                       low_cardinality: Quaack::Enclave::PiiClassification.load(stored).low_cardinality
    )
  end

  it "runs the mechanical search, saves it per search, and prints only its counts and DONE" do
    prepare

    outcome = index_search

    entry = stored.read("index_search_original")
    found = entry["results"].size
    used = entry["results"].count { used?(it) }
    expect([found, used]).to all(be_positive)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([counts_then_done(found:, used:), "", 0])
    expect_no_leaks(sentinels, outcome)
    search = restored_search(entry)
    expect(search.proposals.map { it.sources.to_a.sort }).to include(%i[parse plan])
    expect(search.considered).to eq(search.proposals.size + search.set_aside.size + search.drops.size)
    tested = entry["results"].map { Quaack::Enclave::IndexStore.candidate(it["candidate"]) }
    expect(tested).to eq(search.proposals)
    expect(entry["results"].map { it["candidate"]["sources"] }).to eq(search.proposals.map { sources(it) })
    expect(entry["baseline"].transform_values { it["total_cost"] }).to eq(direct_costs(nil))
    used = entry["results"].find { it["plans"].values.any? { |plan| plan["used"] } }
    expect(used["size"]).to be_a(Integer).and be_positive
    expect(entry["results"].map { it["refusal"] }.uniq).to eq([nil])
    expect(entry["results"].map { it["partial_constant_only"] })
      .to eq(entry["results"].map { !it["candidate"]["predicate"].nil? })
    ddl = Quaack::Enclave::IndexStore.candidate(used["candidate"]).to_ddl
    expect(used["plans"].transform_values { it["total_cost"] }).to eq(direct_costs(ddl))
  end

  def used?(result) = !result["refusal"] && result["plans"].values.any? { it["used"] }

  def burndown = Quaack::Enclave::Burndown.read(stored)

  # Task 20261001-20: index-from-query and index-from-plan, by generator, then index-dedupe and
  # index-test, each counted once however often the step runs.
  it "records index-from-query, index-from-plan, index-dedupe, and index-test in the burndown, once" do
    prepare

    index_search

    entry = stored.read("index_search_original")
    search = restored_search(entry)
    statistics = Quaack::Enclave::PlannerStatistics.load(stored).statistics
    low_cardinality = Quaack::Enclave::PiiClassification.load(stored).low_cardinality
    one = Quaack::Enclave::GeneratorOne.candidates(PgQuery.parse(stored.read("anchored_query")), statistics,
                                                   low_cardinality:).size
    two = search.considered - one
    used = entry["results"].count { used?(it) }
    expect([one, two, used]).to all(be_positive)
    expect(burndown["stages"].transform_values(&:keys)).to eq(
      "index-from-query" => ["original"], "index-from-plan" => ["original"], "index-dedupe" => ["original"],
      "index-test" => ["original"]
    )
    expect(burndown["stages"].transform_values { it["original"] }).to eq(
      "index-from-query" => { "in" => 0, "added" => { "generator_one" => one }, "dropped" => {}, "set_aside" => 0,
                              "out" => one, "extra" => {} },
      "index-from-plan" => { "in" => 0, "added" => { "generator_two" => two }, "dropped" => {}, "set_aside" => 0,
                             "out" => two, "extra" => {} },
      "index-dedupe" => { "in" => one + two, "added" => {}, "dropped" => search.drops.map { it.reason.name }.tally,
                          "set_aside" => search.set_aside.size, "out" => search.proposals.size, "extra" => {} },
      "index-test" => { "in" => entry["results"].size, "added" => {},
                        "dropped" => { "never_used" => entry["results"].size - used }.reject { |_, n| n.zero? },
                        "set_aside" => 0, "out" => used, "extra" => {} }
    )
    expect(burndown["totals"]).to eq("hypothetical_explains" => entry["results"].sum { it["plans"].size })

    before = burndown
    index_search
    expect(burndown).to eq(before)
  end

  context "when a candidate leads with a low-cardinality column (e2e 055)" do
    let(:query) { "SELECT sum(o.total) FROM public.orders o WHERE o.status = 'held'" }

    # 80% of orders are held, as 80% of e2e 055's are shipped.
    def seed(conn)
      conn.exec(<<~SQL)
        CREATE TABLE public.orders (id int PRIMARY KEY, note text, status text, total int, created_at timestamptz);
        INSERT INTO public.orders
        SELECT i, repeat('n', 200), CASE WHEN i % 5 = 0 THEN 'open' ELSE 'held' END, i % 100, now()
        FROM generate_series(1, 20000) AS i;
        ANALYZE public.orders;
      SQL
    end

    it "sets aside each unused key-only B-tree candidate on a low-cardinality leading column for index-build" do
      prepare

      index_search

      entry = stored.read("index_search_original")
      unused = entry["results"].reject { |r| r["refusal"] || r["plans"].values.any? { it["used"] } }
      expected = unused.map { it["candidate"] }.select do |c|
        c["access_method"] == "btree" && c["include"].empty? && c["predicate"].nil? && !c["unique"] &&
          c["key"].first["name"] == "status"
      end
      expect(expected).not_to be_empty
      expect(entry["set_aside"]).to eq(expected)
      expect(entry["set_aside"].map { [it["key"].map { |k| k["name"] }, it["include"]] })
        .to eq([[%w[status total], []], [["status"], []]])
      # 20260927-19: index-test counts them as set aside, not as never used.
      test = burndown.dig("stages", "index-test", "original")
      expect(test&.slice("in", "set_aside", "out")).to eq("in" => entry["results"].size, "set_aside" => 2,
                                                          "out" => entry["results"].count { used?(it) })
      expect(test["dropped"].fetch("never_used", 0)).to eq(unused.size - 2)
    end
  end

  it "stores each plan redacted through redact, with placeholders where the sentinel literal was" do
    prepare
    index_search

    entry = stored.read("index_search_original")
    plans = [*entry["baseline"].values, *entry["results"].flat_map { it["plans"].values }].map { it["plan"] }
    held = JSON.generate(plans)
    expect(plans).to all(be_a(Array))
    expect(held).to include("$1")
    expect(LeakCheck.findings(sentinels, stdout: held)).to eq([])
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(stored.read("plan")))).not_to eq([])
  end

  context "when a literal's type differs from the one Postgres would infer (e2e 020)" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at::date > now()::date - 7"
    end

    it "prepares with the literal's type, and records it as the parameter's type" do
      prepare

      outcome = index_search

      expect([outcome.stdout.lines.last, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
      expect(stored.read("index_search_original")["parameter_types"].values).to include("integer")
    end
  end

  context "when the query selects every column" do
    let(:select_list) { "o.*" }

    it "records a candidate HypoPG refuses, with its rule and SQLSTATE" do
      prepare
      add_ghost_column

      index_search

      refusals = stored.read("index_search_original")["results"].filter_map { it["refusal"] }
      expect(refusals).not_to be_empty
      expect(refusals.uniq).to eq([{ "rule" => "hypopg_refused", "sqlstate" => refusals.first["sqlstate"] }])
      expect(refusals.first["sqlstate"]).to match(/\A[0-9A-Z]{5}\z/)
    end
  end

  it "accepts --search original, and refuses any other search" do
    prepare
    expect(index_search("--search", "original").stdout.lines.last).to eq(%({"type":"done"}\n))

    outcome = index_search("--search", "rewrite_1")
    expect([outcome.stdout, outcome.status.exitstatus]).to eq([error_line("index_search_unknown_search"), 70])
  end

  it "refuses a run whose racetrack isn't set up, storing nothing" do
    prepare(racetrack_setup: false)

    expect_failed(index_search, "index_search_no_racetrack_setup")
  end

  it "fails the plan gate with its rule when the racetrack plans differently, storing nothing" do
    prepare
    conn = production.connect
    conn.exec("CREATE INDEX ON public.orders (note)")
    conn.close

    expect_failed(index_search, "plan_gate_mismatch_likely_stale_statistics")
  end
end

# Task 20261004-1: index-search's step_counts, from its entry.
RSpec.describe Quaack::Enclave::Steps::StepCounts, ".index_search" do
  def result(used, refusal = nil)
    { "refusal" => refusal, "plans" => { "slow" => { "used" => false }, "typical" => { "used" => used } } }
  end

  it "counts every tested candidate as found, and as used only the ones the planner used and HypoPG took" do
    entry = { "results" => [result(true), result(false), result(true, { "rule" => "hypopg_refused" }), result(true)] }

    expect(described_class.index_search(entry)).to eq(type: :step_counts, found: 4, used: 2)
  end
end
