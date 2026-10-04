# frozen_string_literal: true

require "json"
require "quaack/enclave/burndown"
require "quaack/enclave/clock_anchoring"
require "quaack/enclave/index_candidate"
require "quaack/enclave/index_store"
require "quaack/enclave/store"

# `quaacks report-payload --run <run ID>` (DESIGN.md step 15): one report
# message of shape-class data, from the store, with no connection.
# A sentinel that is a lowercase word, as a rule name is.
REPORT_WORD_SENTINEL = "qsentinel_rule_name"

RSpec.describe "quaacks report-payload" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { LeakCheck::Sentinels.new(extra: { planted: "QSENTINEL7741", word: REPORT_WORD_SENTINEL }) }
  let(:sentinel) { sentinels.needles[:planted] }

  after { quaacks.remove }

  def m(blocks, hit, stable: true)
    { "timed_out" => false, "stable" => stable, "total_blocks" => blocks,
      "runs" => [{ "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "execution_ms" => 1.0 }] }
  end

  def node(type, rows, relation: nil, index: nil, plans: [])
    { "Node Type" => type, "Relation Name" => relation, "Schema" => relation && "public", "Index Name" => index,
      "Plan Rows" => rows, "Actual Rows" => rows, "Filter" => "(note = '#{sentinel}'::text)",
      "Plans" => plans }.compact
  end

  let(:redacted_query) { "SELECT id FROM public.orders WHERE created_at > now() - $1::interval AND note = $2" }
  let(:proposed) do
    { "quaack_a" => "CREATE INDEX ON public.orders USING btree (created_at)",
      "quaack_b" => "CREATE INDEX ON public.orders USING btree (created_at, id, note)",
      "quaack_c" => "CREATE INDEX ON public.orders USING btree (id) WHERE note = '#{sentinel}'" }
  end

  def populate(store) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    anchored = Quaack::Enclave::ClockAnchoring.anchor(redacted_query, { "search_path" => "public" })
    store.write("redacted_query", redacted_query)
    store.write("anchored_query", anchored.sql)
    store.write("clock_replacements", "replacements" => anchored.replacements.map { it.to_h.transform_keys(&:to_s) },
                                      "added_names" => [])
    store.write("placeholder_map", "$1" => { "value" => sentinel, "type" => "interval" },
                                   "$2" => { "value" => sentinel, "type" => "text" })
    store.write("literal_sets", "slow" => { "$2" => { "value" => sentinel, "type" => "text" } })
    store.write("statistics", "tables" => [{
                  "schema" => "public", "name" => "orders", "reltuples" => 1000.0,
                  "column_names" => %w[id created_at note], "columns" => {},
                  "indexes" => [{ "name" => "orders_created_at_id_idx", "size_bytes" => 40_960,
                                  "definition" => "CREATE INDEX orders_created_at_id_idx ON public.orders " \
                                                  "USING btree (created_at, id)" }]
                }])
    store.write("classification", "outbound_statistics" => { "tables" => [
                  { "schema" => "public", "name" => "orders", "columns" => [] }
                ] })
    store.write("redacted_plan", "explain" => [{ "Plan" => node("Seq Scan", 50, relation: "orders").except("Schema") }])
    store.write("index_build", "indexes" => proposed.transform_values { { "ddl" => it, "size" => 8192 } },
                               "combinations" => { "original:top:1" => ["quaack_a"], "original:top:2" => ["quaack_b"],
                                                   "rewrite_1:top:1" => %w[quaack_b quaack_c],
                                                   "rewrite_1:top:2" => ["quaack_a"] })
    store.write("baseline", "sets" => { "slow" => m(1000, 100), "typical" => m(200, 150) },
                            "timed_out" => [], "timeout_ms" => 5000)
    # original:top:2 timed out on a set, and so did the run rewrite_1:top:2,
    # which candidate-runs drops without its measurements.
    store.write("index_baseline",
                "combinations" => { "original:top:1" => { "slow" => m(400, 300), "typical" => m(190, 190) },
                                    "original:top:2" => { "slow" => { "timed_out" => true }, "typical" => m(210, 0) } },
                "timed_out" => ["original:top:2"])
    store.write("candidate_runs",
                "candidates" => { "rewrite_1" => { "none" => { "slow" => m(300, 30, stable: false),
                                                               "typical" => m(100, 100) },
                                                   "rewrite_1:top:1" => { "slow" => m(1200, 7),
                                                                          "typical" => m(100, 100) } } },
                "timed_out" => ["rewrite_1:top:2"], "timed_out_count" => 1)
    store.write("minimax", "survivors" => [], "discarded_ties" => [], "infinite_sets" => [],
                           "verdicts" => { "rewrite_1:none" => { "slow" => "better", "typical" => "better" },
                                           "rewrite_1:top:1" => { "slow" => "worse", "typical" => "no_worse" },
                                           "original:top:1" => { "slow" => "better", "typical" => "no_worse" } })
    store.write("selection", "top" => [
                  { "label" => "rewrite_1:none", "slow_blocks" => 300, "total_blocks_sum" => 400, "footprint" => 0 },
                  { "label" => "original:top:1", "slow_blocks" => 400, "total_blocks_sum" => 590,
                    "footprint" => 8192 }
                ], "excluded" => { "rewrite_1:top:1" => "not_better" }, "infinite_sets" => [])
    store.write("rewrite_1", "sql" => "SELECT id FROM public.orders WHERE note = $2 AND created_at > now() - $1",
                             "transformation" => "moved #{sentinel}", "assumptions" => [{ "kind" => sentinel }],
                             "source" => "rule", "rules" => ["key_in_self_join"])
    store.write("rewrite_tested_1", "passed" => true, "scenario" => nil, "rule" => nil, "untested" => 1,
                                    "untested_atoms" => [{ "shape" => "column = $n" }])
    store.write("rewrite_survived_1", "survived" => true, "evidence" => false)
    store.write("index_search_rewrite_1", "baseline" => { "slow" => { "plan" => [{
                  "Plan" => node("Index Scan", 5, relation: "orders", index: "orders_created_at_id_idx")
                }] } })
    Quaack::Enclave::Burndown.record(store, "5a-3", :original, in: 4, dropped: { duplicate: 1 }, out: 3)
    Quaack::Enclave::Burndown.add_totals(store, hypothetical_explains: 12)
  end

  let(:outcome) do
    store = Quaack::Enclave::Store.create(base: quaacks.store_base)
    populate(store)
    quaacks.run("report-payload", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
  end

  let(:report) do
    lines = outcome.stdout.lines.map { JSON.parse(it) }
    expect(lines.last).to eq("type" => "done")
    lines.find { it["type"] == "report" }
  end

  def label(name) = report["labels"].find { it["label"] == name }
  def rewrite(number) = report["rewrites"].find { it["rewrite"] == "rewrite_#{number}" }

  # Runs report-payload on the populated store, changed by the block.
  def payload_of
    store = Quaack::Enclave::Store.create(base: quaacks.store_base)
    populate(store)
    yield store
    quaacks.run("report-payload", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
  end

  it "sends the rankings, and the original's per-literal blocks with hit/read and stability" do
    expect(report["top"].map { it["label"] }).to eq(%w[rewrite_1:none original:top:1])
    expect(report["excluded"]).to eq("rewrite_1:top:1" => "not_better")
    expect(report["original_measurements"]).to eq(
      "slow" => { "total_blocks" => 1000, "hit" => 100, "read" => 900, "stable" => true, "timed_out" => false },
      "typical" => { "total_blocks" => 200, "hit" => 150, "read" => 50, "stable" => true, "timed_out" => false }
    )
  end

  it "sends the original query, with placeholders and the clock functions put back" do
    expect(report["original_sql"])
      .to eq("SELECT id FROM public.orders WHERE created_at > (now() - $1::interval) AND note = $2")
  end

  describe "every measured label, not only the ranked ones" do
    it "lists each of the original's index combinations and each rewrite run, in the order they were measured" do
      expect(report["labels"].map { it["label"] })
        .to eq(%w[original:top:1 original:top:2 rewrite_1:none rewrite_1:top:1 rewrite_1:top:2])
      expect(report["labels"].map { it["search"] }).to eq(%w[original original rewrite_1 rewrite_1 rewrite_1])
    end

    it "sends a ranked label's blocks, per-literal verdicts, and the built indexes it ran with" do
      expect(label("original:top:1")).to eq(
        "label" => "original:top:1", "search" => "original", "indexes" => ["quaack_a"], "timed_out" => false,
        "measurements" => {
          "slow" => { "total_blocks" => 400, "hit" => 300, "read" => 100, "stable" => true, "timed_out" => false },
          "typical" => { "total_blocks" => 190, "hit" => 190, "read" => 0, "stable" => true, "timed_out" => false }
        },
        "verdicts" => { "slow" => "better", "typical" => "no_worse" }
      )
      expect(label("rewrite_1:none")).to include("indexes" => [],
                                                 "verdicts" => { "slow" => "better", "typical" => "better" })
      expect(label("rewrite_1:none")["measurements"]["slow"]).to include("total_blocks" => 300, "stable" => false)
    end

    it "sends the same for a label that wasn't ranked" do
      expect(label("rewrite_1:top:1")).to include(
        "search" => "rewrite_1", "indexes" => %w[quaack_b quaack_c], "timed_out" => false,
        "verdicts" => { "slow" => "worse", "typical" => "no_worse" }
      )
      expect(label("rewrite_1:top:1")["measurements"]["slow"]).to include("total_blocks" => 1200, "hit" => 7,
                                                                          "read" => 1193)
    end

    it "marks an index combination of the original's that timed out, which minimax gave no verdicts" do
      expect(label("original:top:2")).to include(
        "indexes" => ["quaack_b"], "timed_out" => true, "verdicts" => nil,
        "measurements" => { "slow" => { "timed_out" => true },
                            "typical" => { "total_blocks" => 210, "hit" => 0, "read" => 210, "stable" => true,
                                           "timed_out" => false } }
      )
    end

    it "lists a rewrite run dropped for timing out, with its indexes and no measurements" do
      expect(label("rewrite_1:top:2")).to eq("label" => "rewrite_1:top:2", "search" => "rewrite_1",
                                             "indexes" => ["quaack_a"], "timed_out" => true,
                                             "measurements" => nil, "verdicts" => nil)
    end

    context "when a label in the store isn't a label QUAACK makes" do
      let(:outcome) do
        payload_of do |store|
          runs = store.read("candidate_runs")
          runs["candidates"]["rewrite_1"][REPORT_WORD_SENTINEL] = runs["candidates"]["rewrite_1"]["none"]
          store.write("candidate_runs", runs.merge("timed_out" => [REPORT_WORD_SENTINEL, "rewrite_1:top:2"]))
        end
      end

      it "doesn't send it" do
        expect(report["labels"].map { it["label"] })
          .to eq(%w[original:top:1 original:top:2 rewrite_1:none rewrite_1:top:1 rewrite_1:top:2])
        expect_no_leaks(sentinels, outcome)
      end
    end
  end

  describe "every stored rewrite" do
    it "sends a ranked rewrite's SQL, plan, untested atoms, and step 10 evidence" do
      expect(rewrite(1)).to include(
        "sql" => "SELECT id FROM public.orders WHERE note = $2 AND created_at > now() - $1",
        "untested_atoms" => [{ "shape" => "column = $n" }], "evidence" => false
      )
      expect(rewrite(1)["plan"].first).to include("node" => "Index Scan", "index" => "orders_created_at_id_idx",
                                                  "selectivity" => 0.005)
    end

    context "with a rewrite that was stored and taken no further" do
      let(:outcome) { payload_of { it.write("rewrite_2", "sql" => "SELECT $1", "source" => "operator") } }

      it "sends its SQL and source all the same, with nothing it doesn't have" do
        expect(report["rewrites"].map { it["rewrite"] }).to eq(%w[rewrite_1 rewrite_2])
        expect(rewrite(2)).to eq("rewrite" => "rewrite_2", "sql" => "SELECT $1", "source" => "operator",
                                 "rules" => nil, "empirical" => nil, "fate" => "unfinished", "scenario" => nil,
                                 "rule" => nil, "round" => nil, "after" => nil, "cycle" => nil, "plan" => nil,
                                 "untested_atoms" => nil, "evidence" => nil)
      end
    end
  end

  describe "each rewrite's fate" do
    def tested(passed, scenario = nil, rule = nil)
      { "passed" => passed, "scenario" => scenario, "rule" => rule, "untested" => [], "untested_atoms" => [] }
    end

    # Stores rewrite_<number> as far as the steps given took it: tested is
    # rewrite_tested_<n>, round is rewrite_round_<n>, survived is
    # rewrite_survived_<n>'s survived, and pruned is rewrite_pruned_<n>'s
    # discarded.
    def stored(store, number, tested: nil, round: nil, survived: nil, pruned: nil) # rubocop:disable Metrics/ParameterLists
      store.write("rewrite_#{number}", "sql" => "SELECT #{number}", "source" => "llm")
      store.write("rewrite_pruned_#{number}", "discarded" => pruned) unless pruned.nil?
      store.write("rewrite_tested_#{number}", tested) if tested
      store.write("rewrite_round_#{number}", round) if round
      store.write("rewrite_survived_#{number}", "survived" => survived) unless survived.nil?
    end

    # A rewrite that passed steps 9 and 10, measured under each key
    # (none, or a combination key), with 14d's reason for each label.
    def measured(store, number, reasons)
      stored(store, number, tested: tested(true), round: { "round" => 3, "evidence" => true, "rule" => nil },
                            survived: true, pruned: false)
      runs = store.read("candidate_runs")
      runs["candidates"]["rewrite_#{number}"] = reasons.keys.to_h { [it, { "slow" => m(900, 1) }] }
      store.write("candidate_runs", runs)
      labels = reasons.transform_keys { it == "none" ? "rewrite_#{number}:none" : it }.compact
      selection = store.read("selection")
      store.write("selection", selection.merge("excluded" => selection["excluded"].merge(labels)))
    end

    # 14c's entry, as ResultComparison.entry writes it, from each
    # rewrite's verdict rule by literal set (nil for a pass).
    def compared(store, rules)
      verdicts = rules.to_h do |number, sets|
        ["rewrite_#{number}", sets.transform_values { { "result" => it ? "fail" : "pass", "rule" => it } }]
      end
      failed = verdicts.select { |_, sets| sets.values.any? { it["result"] == "fail" } }.keys
      store.write("result_comparison", "verdicts" => verdicts, "discarded" => failed, "partial_count" => 0)
    end

    def fate(number) = rewrite(number).slice("fate", "scenario", "rule", "round", "after").compact

    let(:outcome) do
      payload_of do |store|
        stored(store, 2, pruned: true, tested: tested(false, nil, "discarded"), survived: false)
        stored(store, 3, pruned: false, tested: tested(false, "s3", "multiset"), survived: false)
        stored(store, 4, pruned: false, tested: tested(false, "s0", "unsupported_order"), survived: false)
        stored(store, 5, tested: tested(false, "s2", "query_failed"), survived: false)
        stored(store, 6, tested: tested(true), round: { "round" => 2, "evidence" => true, "rule" => "row_count" },
                         survived: false)
        stored(store, 7, tested: tested(true), survived: false,
                         round: { "round" => 1, "evidence" => true, "rule" => "statement_timeout" })
        measured(store, 8, "none" => "result_mismatch")
        measured(store, 9, "none" => "result_mismatch", "rewrite_9:top:1" => "not_better")
        measured(store, 10, "none" => "not_better")
        compared(store, 8 => { "slow" => "timed_out", "typical" => "multiset" },
                        9 => { "slow" => "timed_out", "typical" => nil },
                        10 => { "slow" => "unsupported_order", "typical" => "unsupported_order" },
                        11 => { "slow" => nil, "typical" => nil })
        measured(store, 11, "none" => "not_better", "rewrite_11:top:1" => "not_better")
        measured(store, 12, "none" => "not_better", "rewrite_12:top:1" => "footprint_tie")
        measured(store, 13, "none" => "footprint_tie", "rewrite_13:top:1" => "below_top_three",
                            "rewrite_13:top:2" => "not_better")
        stored(store, 14, tested: tested(true), round: { "round" => 3, "evidence" => true, "rule" => nil },
                          survived: true)
        runs = store.read("candidate_runs")
        store.write("candidate_runs", runs.merge("timed_out" => [*runs["timed_out"], "rewrite_14:none",
                                                                 "rewrite_14:top:1"]))
        stored(store, 15)
        stored(store, 16, tested: tested(true), round: { "round" => 1, "evidence" => true, "rule" => nil })
        stored(store, 17, tested: tested(true), round: { "round" => 3, "evidence" => true, "rule" => nil },
                          survived: true)
        measured(store, 18, "none" => nil)
        # As a store written before rounds kept their rule holds them.
        stored(store, 19, tested: tested(true), round: { "round" => 3, "evidence" => true }, survived: false)
        stored(store, 20, tested: tested(true), survived: false)
        # A rewrite step 8 pruned that rewrite-test never reached.
        stored(store, 21, pruned: true)
        # A rewrite ranked under one label and excluded under another.
        measured(store, 22, "none" => "not_better", "rewrite_22:top:1" => nil)
        selection = store.read("selection")
        store.write("selection", selection.merge("top" => [*selection["top"], { "label" => "rewrite_22:top:1" }]))
        # No run stores this: a rewrite step 9 disproved is never measured.
        # If a store held both, the earlier step is the fate.
        measured(store, 23, "none" => "not_better")
        store.write("rewrite_tested_23", tested(false, "s1", "value"))
        # Step 9 couldn't build scenarios for the query, so it refused.
        { 24 => "complex_check", 25 => "fk_cycle", 26 => REPORT_WORD_SENTINEL, 27 => "unsatisfiable_check",
          28 => "expression_unique_index", 29 => "unsupported_type", 30 => "domain_check" }.each do |number, rule|
          stored(store, number, tested: tested(false, nil, rule).merge("refused" => true), survived: false)
        end
      end
    end

    {
      1 => { "fate" => "ranked" },
      2 => { "fate" => "same_plans" },
      3 => { "fate" => "step9_disproved", "scenario" => "s3", "rule" => "multiset" },
      4 => { "fate" => "step9_failed", "scenario" => "s0", "rule" => "unsupported_order" },
      5 => { "fate" => "step9_failed", "scenario" => "s2", "rule" => "query_failed" },
      6 => { "fate" => "step10_disproved", "round" => 2, "rule" => "row_count" },
      7 => { "fate" => "step10_failed", "round" => 1, "rule" => "statement_timeout" },
      8 => { "fate" => "production_mismatch", "rule" => "multiset" },
      9 => { "fate" => "production_timed_out" },
      10 => { "fate" => "production_not_compared", "rule" => "unsupported_order" },
      11 => { "fate" => "not_better" },
      12 => { "fate" => "footprint_tie" },
      13 => { "fate" => "below_top_three" },
      14 => { "fate" => "measurement_timed_out" },
      15 => { "fate" => "unfinished" },
      16 => { "fate" => "unfinished", "after" => "step9" },
      17 => { "fate" => "unfinished", "after" => "step10" },
      18 => { "fate" => "unfinished", "after" => "measurement" },
      19 => { "fate" => "step10_disproved", "round" => 3 },
      20 => { "fate" => "step10_disproved" },
      21 => { "fate" => "same_plans" },
      22 => { "fate" => "ranked" },
      23 => { "fate" => "step9_disproved", "scenario" => "s1", "rule" => "value" },
      24 => { "fate" => "step9_untested", "rule" => "complex_check" },
      25 => { "fate" => "step9_untested", "rule" => "fk_cycle" },
      26 => { "fate" => "step9_untested" },
      27 => { "fate" => "step9_untested", "rule" => "unsatisfiable_check" },
      28 => { "fate" => "step9_untested", "rule" => "expression_unique_index" },
      29 => { "fate" => "step9_untested", "rule" => "unsupported_type" },
      30 => { "fate" => "step9_untested", "rule" => "domain_check" }
    }.each do |number, expected|
      it "gives rewrite_#{number} the fate #{expected.values.join(", ")}" do
        expect(fate(number)).to eq(expected)
      end
    end

    it "sends step 10 evidence only for a rewrite that survived step 10" do
      expect([3, 6, 16].map { rewrite(it)["evidence"] }).to eq([nil, nil, nil])
      expect(rewrite(17)["evidence"]).to be(true)
    end

    it "never calls a rewrite step 8 pruned disproved, though rewrite-test stores it as not passed" do
      expect(report["rewrites"].select { it["fate"].include?("disproved") }.map { it["rewrite"] })
        .to eq(%w[rewrite_3 rewrite_6 rewrite_19 rewrite_20 rewrite_23])
    end

    context "when the store holds rule, scenario, and round values that aren't QUAACK's own" do
      let(:outcome) do
        payload_of do |store|
          stored(store, 2, tested: tested(false, REPORT_WORD_SENTINEL, REPORT_WORD_SENTINEL), survived: false)
          stored(store, 3, tested: tested(true), survived: false,
                           round: { "round" => REPORT_WORD_SENTINEL, "evidence" => true,
                                    "rule" => REPORT_WORD_SENTINEL })
          stored(store, 4, tested: tested(true), survived: false,
                           round: { "round" => 7, "evidence" => true, "rule" => "multiset" })
          measured(store, 5, "none" => "result_mismatch")
          measured(store, 6, "none" => "not_better")
          compared(store, 5 => { "slow" => REPORT_WORD_SENTINEL }, 6 => { REPORT_WORD_SENTINEL => nil })
        end
      end

      it "sends a fate that claims no disproof, and none of the values" do
        expect([2, 3, 4, 5, 6].map { fate(it) }).to eq(
          [{ "fate" => "step9_failed" }, { "fate" => "step10_failed" },
           { "fate" => "step10_disproved", "rule" => "multiset" }, { "fate" => "production_not_compared" },
           { "fate" => "not_better" }]
        )
        expect_no_leaks(sentinels, outcome)
      end
    end

    # An fk_cycle refusal's tables are schema, and go out only if each is
    # a relation the run's schema subset holds.
    context "when step 9 refused for fk_cycle and stored the cycle's tables" do
      def refused(rule, cycle) = tested(false, nil, rule).merge("refused" => true, "cycle" => cycle)

      let(:cycle) { [%w[public orders], %w[billing accounts], %w[public orders]] }
      let(:outcome) do
        payload_of do |store|
          store.write("schema_subset", "tables" => [%w[public orders], %w[billing accounts]], "ddl" => "")
          stored(store, 2, tested: refused("fk_cycle", cycle), survived: false)
          stored(store, 3, tested: refused("fk_cycle", [%w[public orders], ["public", sentinel], %w[public orders]]),
                           survived: false)
          stored(store, 4, tested: refused("fk_cycle", "public.orders -> #{sentinel} -> public.orders"),
                           survived: false)
          stored(store, 5, tested: refused("fk_cycle", [%w[public orders], %w[billing accounts], %w[billing accounts]]),
                           survived: false)
          stored(store, 6, tested: refused("complex_check", cycle), survived: false)
          stored(store, 7, tested: refused("fk_cycle", [%w[public orders], [REPORT_WORD_SENTINEL, "orders"],
                                                        %w[public orders]]), survived: false)
        end
      end

      it "sends them schema-qualified, in the order their foreign keys point" do
        expect(rewrite(2)).to include("fate" => "step9_untested", "rule" => "fk_cycle",
                                      "cycle" => %w[public.orders billing.accounts public.orders])
      end

      it "sends no cycle that names a table the schema doesn't hold, isn't a list of tables, or doesn't close" do
        expect([3, 4, 5, 7].map { rewrite(it).slice("rule", "cycle") }).to all(eq("rule" => "fk_cycle", "cycle" => nil))
        expect_no_leaks(sentinels, outcome)
      end

      it "sends no tables for any other rule" do
        expect(rewrite(6)).to include("rule" => "complex_check", "cycle" => nil)
      end
    end
  end

  describe "where each rewrite came from (6c)" do
    def rewrite_candidate = rewrite(1)

    # Runs report-payload on the populated store with rewrite_1 changed.
    def with_rewrite(**fields)
      store = Quaack::Enclave::Store.create(base: quaacks.store_base)
      populate(store)
      store.write("rewrite_1", store.read("rewrite_1").merge(fields.transform_keys(&:to_s)).compact)
      yield store if block_given?
      report_payload(store)
    end

    def report_payload(store)
      quaacks.run("report-payload", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
    end

    it "sends a rule-made rewrite as source rule, with the rules applied, in order" do
      expect(rewrite_candidate).to include("source" => "rule", "rules" => ["key_in_self_join"])
    end

    %w[llm operator].each do |source|
      context "for a rewrite of source #{source}" do
        let(:outcome) { with_rewrite(source:, rules: nil) }

        it "sends the source, and no rules" do
          expect(rewrite_candidate).to include("source" => source, "rules" => nil)
        end
      end
    end

    context "for a rewrite stored before rewrites had a source" do
      let(:outcome) { with_rewrite(source: nil, rules: nil) }

      it "sends no source" do
        expect(rewrite_candidate).to include("source" => nil, "rules" => nil)
      end
    end

    context "when a stored rewrite holds a source and rule names that aren't QUAACK's own" do
      let(:outcome) { with_rewrite(source: REPORT_WORD_SENTINEL, rules: [REPORT_WORD_SENTINEL]) }

      it "sends neither" do
        expect(rewrite_candidate).to include("source" => nil, "rules" => nil)
        expect_no_leaks(sentinels, outcome)
      end
    end

    context "when a rule-made rewrite's rules hold a name that isn't one of QUAACK's rules" do
      let(:outcome) { with_rewrite(rules: [REPORT_WORD_SENTINEL, "key_in_self_join", sentinel, 7]) }

      it "sends only QUAACK's own rule names" do
        expect(rewrite_candidate).to include("source" => "rule", "rules" => ["key_in_self_join"])
        expect_no_leaks(sentinels, outcome)
      end
    end

    describe "empirical: what a rule-made rewrite assumes of the data and the schema doesn't enforce" do
      let(:copy_sql) do
        "SELECT s.id FROM public.submissions s JOIN public.assignments a ON a.id = s.assignment_id " \
          "WHERE a.context_type = $1 AND a.context_id = $2 AND s.course_id = $2"
      end
      let(:empirical) do
        { "table" => "public.submissions", "column" => "course_id", "references_table" => "public.assignments",
          "type_column" => "context_type", "id_column" => "context_id" }
      end

      def denormalized(**fields)
        { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => "course_id",
          "join_column" => "assignment_id", "references_table" => "public.assignments", "references_column" => "id",
          "type_column" => "context_type", "type_value" => sentinel, "id_column" => "context_id" }
          .merge(fields.transform_keys(&:to_s))
      end

      context "with a denormalized_equal assumption whose names are the rewrite's own" do
        let(:outcome) do
          with_rewrite(sql: copy_sql, rules: ["polymorphic_key_copy"],
                       assumptions: [{ "kind" => "not_null", "table" => "public.orders", "column" => "id" },
                                     denormalized])
        end

        it "sends the tables and columns it rests on, and never the type value" do
          expect_no_leaks(sentinels, outcome)
          expect(rewrite_candidate).to include("source" => "rule", "rules" => ["polymorphic_key_copy"],
                                               "empirical" => [empirical])
        end
      end

      context "with a denormalized_equal assumption naming what the rewrite's SQL doesn't" do
        let(:outcome) do
          with_rewrite(sql: copy_sql, assumptions: [denormalized(column: REPORT_WORD_SENTINEL),
                                                    denormalized(references_table: "public.#{REPORT_WORD_SENTINEL}")])
        end

        it "sends none of it" do
          expect_no_leaks(sentinels, outcome)
          expect(rewrite_candidate).to include("empirical" => [])
        end
      end

      it "sends no empirical assumption for a rule-made rewrite that rests on none" do
        expect(rewrite_candidate).to include("empirical" => [])
      end

      context "for a rewrite of another source" do
        let(:outcome) { with_rewrite(sql: copy_sql, source: "llm", rules: nil, assumptions: [denormalized]) }

        it "sends none" do
          expect(rewrite_candidate).to include("source" => "llm", "empirical" => nil)
        end
      end
    end

    describe "rule_bugs: rule-made rewrites that a test disproved" do
      def tested(passed, rule = nil, scenario = nil)
        { "passed" => passed, "scenario" => scenario, "rule" => rule, "untested" => 0, "untested_atoms" => [] }
      end

      def rule_made(store, number, tested, survived, rules: %w[key_in_self_join key_in_self_join], assumptions: nil) # rubocop:disable Metrics/ParameterLists
        store.write("rewrite_#{number}", { "sql" => "SELECT #{number}", "source" => "rule", "rules" => rules,
                                           "assumptions" => assumptions }.compact)
        store.write("rewrite_tested_#{number}", tested)
        store.write("rewrite_survived_#{number}", "survived" => survived)
      end

      # Writes 14c's entry as ResultComparison.entry does, from each
      # rewrite's verdict rules by literal set (nil for a pass).
      def compared(store, **rules)
        verdicts = rules.to_h do |number, sets|
          ["rewrite_#{number}", sets.transform_keys(&:to_s).transform_values do |rule|
            { "result" => rule ? "fail" : "pass", "rule" => rule }
          end]
        end
        failed = verdicts.select { |_, sets| sets.values.any? { it["result"] == "fail" } }.keys
        store.write("result_comparison", "verdicts" => verdicts, "discarded" => failed, "partial_count" => 0)
      end

      it "is empty when no rule-made rewrite was disproved" do
        expect(report["rule_bugs"]).to eq([])
      end

      context "with rule-made rewrites that steps 9, 10, and 14c disproved, though a candidate won" do
        let(:outcome) do
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "multiset", "s3"), false)
            rule_made(store, 3, tested(true), false)
            rule_made(store, 4, tested(true), true)
            compared(store, "4": { slow: nil, typical: "multiset" })
          end
        end

        it "names each one, its rules, and the step that disproved it" do
          expect(report["top"]).not_to be_empty
          both = %w[key_in_self_join key_in_self_join]
          expect(report["rule_bugs"]).to eq(
            [{ "rewrite" => "rewrite_2", "rules" => both, "step" => "step9" },
             { "rewrite" => "rewrite_3", "rules" => both, "step" => "step10" },
             { "rewrite" => "rewrite_4", "rules" => both, "step" => "14c" }]
          )
        end
      end

      # 14c drops a candidate for any failing verdict, but only a result
      # mismatch disproves it.
      %w[timed_out unsupported_order].each do |rule|
        context "with a rule-made rewrite that 14c dropped only as #{rule}" do
          let(:outcome) do
            with_rewrite do |store|
              rule_made(store, 2, tested(true), true)
              compared(store, "2": { slow: rule, typical: nil, worst_case: rule })
            end
          end

          it "isn't a bug: 14c never compared its results" do
            expect(report["rule_bugs"]).to eq([])
          end
        end
      end

      %w[column_count column_types row_count value multiset subset candidate_unordered].each do |rule|
        context "with a rule-made rewrite whose 14c results differed, rule #{rule}, on one literal set" do
          let(:outcome) do
            with_rewrite do |store|
              rule_made(store, 2, tested(true), true)
              compared(store, "2": { slow: "timed_out", typical: rule, worst_case: nil })
            end
          end

          it "is a bug, though 14c timed out on another set" do
            expect(report["rule_bugs"]).to eq([{ "rewrite" => "rewrite_2", "step" => "14c",
                                                 "rules" => %w[key_in_self_join key_in_self_join] }])
          end
        end
      end

      context "with a disproved rule-made rewrite whose stored rules hold names that aren't QUAACK's own" do
        let(:outcome) do
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "multiset", "s3"), false,
                      rules: [REPORT_WORD_SENTINEL, "key_in_self_join", sentinel])
          end
        end

        it "names only QUAACK's own rules in rule_bugs, and leaks neither" do
          expect(report["rule_bugs"]).to eq([{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"],
                                               "step" => "step9" }])
          expect_no_leaks(sentinels, outcome)
        end
      end

      # Steps 9 and 10 make up their data, which needn't hold an assumption
      # 6b found the real data holds; 14c runs on the racetrack's.
      context "with rule-made rewrites resting on a denormalized_equal assumption, disproved by 9, 10, and 14c" do
        let(:outcome) do
          assumptions = [{ "kind" => "denormalized_equal", "table" => "public.submissions" }]
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "multiset", "s3"), false, rules: ["polymorphic_key_copy"], assumptions:)
            rule_made(store, 3, tested(true), false, rules: ["polymorphic_key_copy"], assumptions:)
            rule_made(store, 4, tested(true), true, rules: ["polymorphic_key_copy"], assumptions:)
            compared(store, "4": { slow: "multiset" })
          end
        end

        it "calls only the 14c disproof a bug" do
          expect(report["rule_bugs"]).to eq([{ "rewrite" => "rewrite_4", "rules" => ["polymorphic_key_copy"],
                                               "step" => "14c" }])
        end
      end

      context "with a rule-made rewrite that step 8 pruned for planning as the original does" do
        let(:outcome) { with_rewrite { rule_made(it, 2, tested(false, "discarded"), false) } }

        it "isn't a bug: a pruned rewrite was never disproved" do
          expect(report["rule_bugs"]).to eq([])
        end
      end

      context "with a rule-made rewrite step 9 refused to test, since it couldn't build scenarios" do
        let(:outcome) do
          with_rewrite { rule_made(it, 2, tested(false, "complex_check").merge("refused" => true), false) }
        end

        it "isn't a bug: a refused rewrite was never tested" do
          expect(report["rule_bugs"]).to eq([])
        end
      end

      context "with rewrites the LLM and the operator made that were disproved" do
        let(:outcome) do
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "multiset", "s3"), false)
            store.write("rewrite_2", "sql" => "SELECT 2", "source" => "llm")
            rule_made(store, 3, tested(true), true)
            store.write("rewrite_3", "sql" => "SELECT 3", "source" => "operator")
            compared(store, "3": { slow: "row_count" })
          end
        end

        it "flags neither" do
          expect(report["rule_bugs"]).to eq([])
        end
      end
    end
  end

  it "sends each proposed index's redacted DDL, size, prefix coverage, and redundancy" do
    expect(report["indexes"]["quaack_a"]).to eq(
      "ddl" => "CREATE INDEX ON public.orders USING btree (created_at)", "size" => 8192,
      "covered_by" => { "name" => "orders_created_at_id_idx", "size_bytes" => 40_960 }, "makes_redundant" => []
    )
    expect(report["indexes"]["quaack_b"]).to include(
      "covered_by" => nil, "makes_redundant" => [{ "name" => "orders_created_at_id_idx", "size_bytes" => 40_960 }]
    )
    expect(report["indexes"]["quaack_c"]["ddl"]).to include("note = ?")
  end

  context "when the statistics hold no size for an existing index, or one that isn't a number" do
    let(:outcome) do
      payload_of do |store|
        statistics = store.read("statistics")
        statistics["tables"].first["indexes"].first["size_bytes"] = sentinel
        store.write("statistics", statistics)
      end
    end

    it "sends the index's name with no size" do
      expect(report["indexes"]["quaack_a"]["covered_by"]).to eq("name" => "orders_created_at_id_idx",
                                                                "size_bytes" => nil)
      expect_no_leaks(sentinels, outcome)
    end
  end

  it "sends the recorded burndown counts (15b)" do
    expect(report["burndown"]).to eq(
      "stages" => { "5a-3" => { "original" => { "in" => 4, "added" => {}, "dropped" => { "duplicate" => 1 },
                                                "set_aside" => 0, "out" => 3, "extra" => {} } } },
      "totals" => { "hypothetical_explains" => 12 }
    )
  end

  it "sends plan node shapes with selectivities" do
    expect(report["original_plan"]).to eq([{ "node" => "Seq Scan", "relation" => "public.orders", "index" => nil,
                                             "est_rows" => 50, "actual_rows" => 50, "selectivity" => 0.05 }])
  end

  it "never sends a literal value or a row value" do
    expect(report).not_to be_nil
    expect_no_leaks(sentinels, outcome)
  end

  describe "when nothing beats the original (15a)" do
    def plain(ddl)
      candidate = Quaack::Enclave::IndexCandidate.from_ddl(ddl, sources: [:generator_one])
      Quaack::Enclave::IndexStore.candidate_plain(candidate)
    end

    def result(ddl, used:, refusal: nil)
      { "candidate" => plain("CREATE INDEX ON public.orders USING #{ddl}"), "size" => refusal ? nil : 8192,
        "refusal" => refusal, "plans" => refusal ? {} : { "slow" => { "used" => used, "total_cost" => 1.0 } } }
    end

    def covered(ddl)
      existing = "CREATE INDEX orders_created_at_id_idx ON public.orders USING btree (created_at, id)"
      { "candidate" => plain("CREATE INDEX ON public.orders USING #{ddl}"), "reason" => "covered_by_existing",
        "covered_by" => { "existing" => "orders_created_at_id_idx", "definition" => plain(existing) } }
    end

    def dedupe(*drops) = { "proposals" => [], "set_aside" => [], "considered" => drops.size, "drops" => drops }

    let(:partial) { "btree (note) WHERE note = '#{sentinel}'" }
    let(:refused) { result("gin (note)", used: false, refusal: { "rule" => "hypopg_refused", "sqlstate" => "0A000" }) }

    def populate_negative(store) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      populate(store)
      store.write("selection", "top" => [], "infinite_sets" => [],
                               "excluded" => { "rewrite_1:none" => "not_better", "rewrite_1:top:1" => "not_better" })
      # btree (status) is unused but set aside for 12a (20260927-11), so it
      # isn't declined. The partial index comes up three times in the
      # original's search: from the generators, again from the LLM, and
      # once more as a plan prints it, with a cast on its constant.
      store.write("index_search_original",
                  "dedupe" => dedupe(covered("btree (created_at)"),
                                     covered("btree (created_at) WHERE note = '#{sentinel}'"),
                                     covered("btree (created_at)"),
                                     { "candidate" => plain("CREATE INDEX ON public.orders USING btree (id)"),
                                       "reason" => "duplicate", "covered_by" => nil }),
                  "results" => [result("btree (status)", used: false), result(partial, used: false), refused,
                                result("btree (id, note)", used: true),
                                result("btree (note) WHERE (note)::text = '#{sentinel}'::text", used: false)],
                  "llm_results" => [result(partial, used: false)],
                  "set_aside" => [plain("CREATE INDEX ON public.orders USING btree (status)")])
      # The rewrite's search repeats the original's lines, and adds one.
      store.write("index_search_rewrite_1",
                  store.read("index_search_rewrite_1").merge(
                    "dedupe" => dedupe(covered("btree (created_at) WHERE note = '#{sentinel}'::text"),
                                       covered("btree (created_at, id)")),
                    "results" => [result(partial, used: false), result("btree (id)", used: false)],
                    "llm_results" => [refused]
                  ))
    end

    let(:outcome) do
      store = Quaack::Enclave::Store.create(base: quaacks.store_base)
      populate_negative(store)
      quaacks.run("report-payload", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
    end

    it "sends each index the planner declined once, with why, redacted DDL, and the searches it came up in" do
      expect(report["negative"]["declined"]).to eq(
        [{ "ddl" => "CREATE INDEX ON public.orders USING btree (note) WHERE note = ?", "reason" => "unused",
           "sqlstate" => nil, "searches" => %w[original rewrite_1] },
         { "ddl" => "CREATE INDEX ON public.orders USING gin (note)", "reason" => "hypopg_refused",
           "sqlstate" => "0A000", "searches" => %w[original rewrite_1] },
         { "ddl" => "CREATE INDEX ON public.orders USING btree (id)", "reason" => "unused", "sqlstate" => nil,
           "searches" => ["rewrite_1"] }]
      )
    end

    it "sends each proposed index that already existed once, with the existing index's name and size" do
      by = { "name" => "orders_created_at_id_idx", "size_bytes" => 40_960 }
      expect(report["negative"]["existing"]).to eq(
        [{ "ddl" => "CREATE INDEX ON public.orders USING btree (created_at)", "covered_by" => by,
           "searches" => ["original"] },
         { "ddl" => "CREATE INDEX ON public.orders USING btree (created_at) WHERE note = ?", "covered_by" => by,
           "searches" => %w[original rewrite_1] },
         { "ddl" => "CREATE INDEX ON public.orders USING btree (created_at, id)", "covered_by" => by,
           "searches" => ["rewrite_1"] }]
      )
    end

    it "sends the original query, every rewrite, and every measured label, though none was ranked" do
      expect(report["top"]).to eq([])
      expect(report["original_sql"]).to include("now() - $1::interval").and include("note = $2")
      expect(report["rewrites"].map { it.slice("rewrite", "sql", "fate") }).to eq(
        [{ "rewrite" => "rewrite_1", "fate" => "not_better",
           "sql" => "SELECT id FROM public.orders WHERE note = $2 AND created_at > now() - $1" }]
      )
      expect(label("original:top:1")["measurements"]["slow"]).to include("total_blocks" => 400)
      expect(label("rewrite_1:top:1")).to include("indexes" => %w[quaack_b quaack_c])
    end

    context "when a stored refusal holds a rule and a SQLSTATE that aren't QUAACK's or Postgres's own" do
      let(:refused) do
        result("gin (note)", used: false, refusal: { "rule" => REPORT_WORD_SENTINEL, "sqlstate" => sentinel })
      end

      it "sends the declined index with neither" do
        expect(report["negative"]["declined"][1]).to eq(
          "ddl" => "CREATE INDEX ON public.orders USING gin (note)", "reason" => nil, "sqlstate" => nil,
          "searches" => %w[original rewrite_1]
        )
        expect_no_leaks(sentinels, outcome)
      end
    end

    it "sends only the two index lists: the rewrites' fates say what the rest did" do
      expect(report["negative"].keys).to eq(%w[declined existing])
    end

    it "never sends a literal value" do
      expect(report["negative"]).not_to be_nil
      expect_no_leaks(sentinels, outcome)
    end
  end

  it "sends no negative result when a candidate beat the original" do
    expect(report["negative"]).to be_nil
  end
end
