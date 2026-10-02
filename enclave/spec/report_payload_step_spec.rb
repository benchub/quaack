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
                  "indexes" => [{ "name" => "orders_created_at_id_idx",
                                  "definition" => "CREATE INDEX orders_created_at_id_idx ON public.orders " \
                                                  "USING btree (created_at, id)" }]
                }])
    store.write("classification", "outbound_statistics" => { "tables" => [
                  { "schema" => "public", "name" => "orders", "columns" => [] }
                ] })
    store.write("redacted_plan", "explain" => [{ "Plan" => node("Seq Scan", 50, relation: "orders").except("Schema") }])
    store.write("index_build", "indexes" => proposed.transform_values { { "ddl" => it, "size" => 8192 } },
                               "combinations" => { "original:top:1" => ["quaack_a"],
                                                   "rewrite_1:top:1" => %w[quaack_b quaack_c] })
    store.write("baseline", "sets" => { "slow" => m(1000, 100), "typical" => m(200, 150) },
                            "timed_out" => [], "timeout_ms" => 5000)
    store.write("index_baseline", "combinations" => { "original:top:1" => { "slow" => m(400, 300),
                                                                            "typical" => m(190, 190) } },
                                  "timed_out" => [])
    store.write("candidate_runs", "candidates" => { "rewrite_1" => { "none" => { "slow" => m(300, 30, stable: false),
                                                                                 "typical" => m(100, 100) } } },
                                  "timed_out" => [], "timed_out_count" => 0)
    store.write("minimax", "survivors" => [], "discarded_ties" => [], "infinite_sets" => [],
                           "verdicts" => { "rewrite_1:none" => { "slow" => "better", "typical" => "better" },
                                           "original:top:1" => { "slow" => "better", "typical" => "no_worse" } })
    store.write("selection", "top" => [
                  { "label" => "rewrite_1:none", "slow_blocks" => 300, "total_blocks_sum" => 400, "footprint" => 0 },
                  { "label" => "original:top:1", "slow_blocks" => 400, "total_blocks_sum" => 590,
                    "footprint" => 8192 }
                ], "excluded" => { "rewrite_1:top:1" => "worse" }, "infinite_sets" => [])
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

  it "sends the rankings, per-literal blocks with hit/read and stability" do
    expect(report["top"].map { it["label"] }).to eq(%w[rewrite_1:none original:top:1])
    expect(report["excluded"]).to eq("rewrite_1:top:1" => "worse")
    expect(report["verdicts"]["original:top:1"]).to eq("slow" => "better", "typical" => "no_worse")
    expect(report["measurements"]["original"]["slow"]).to eq("total_blocks" => 1000, "hit" => 100, "read" => 900,
                                                             "stable" => true, "timed_out" => false)
    expect(report["measurements"]["rewrite_1:none"]["slow"]).to include("total_blocks" => 300, "stable" => false)
    expect(report["measurements"]["original:top:1"]["typical"]).to include("hit" => 190, "read" => 0)
  end

  it "sends each top candidate's query with placeholders and the clock functions put back" do
    original = report["candidates"].find { it["label"] == "original:top:1" }
    expect(original["sql"]).to include("now()").and include("$2")
    expect(original["sql"]).not_to include("clock_anchor")
    rewrite = report["candidates"].find { it["label"] == "rewrite_1:none" }
    expect(rewrite["sql"]).to start_with("SELECT id FROM public.orders WHERE note = $2")
    expect(rewrite["untested_atoms"]).to eq([{ "shape" => "column = $n" }])
    expect(rewrite["evidence"]).to be(false)
    expect(original["indexes"]).to eq(["quaack_a"])
  end

  describe "where each rewrite came from (6c)" do
    def rewrite_candidate = report["candidates"].find { it["label"] == "rewrite_1:none" }

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

    it "sends no source for a candidate that is the original query" do
      expect(report["candidates"].find { it["label"] == "original:top:1" }.keys).not_to include("source", "rules")
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

    describe "rule_bugs: rule-made rewrites that a test disproved" do
      def tested(passed, rule = nil, scenario = nil)
        { "passed" => passed, "scenario" => scenario, "rule" => rule, "untested" => 0, "untested_atoms" => [] }
      end

      def rule_made(store, number, tested, survived)
        store.write("rewrite_#{number}", "sql" => "SELECT #{number}", "source" => "rule",
                                         "rules" => %w[key_in_self_join key_in_self_join])
        store.write("rewrite_tested_#{number}", tested)
        store.write("rewrite_survived_#{number}", "survived" => survived)
      end

      it "is empty when no rule-made rewrite was disproved" do
        expect(report["rule_bugs"]).to eq([])
      end

      context "with rule-made rewrites that steps 9, 10, and 14c disproved, though a candidate won" do
        let(:outcome) do
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "null_semantics", "S3"), false)
            rule_made(store, 3, tested(true), false)
            rule_made(store, 4, tested(true), true)
            store.write("result_comparison", "verdicts" => {}, "discarded" => ["rewrite_4"], "partial_count" => 0)
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

      context "with a rule-made rewrite that step 8 pruned for planning as the original does" do
        let(:outcome) { with_rewrite { rule_made(it, 2, tested(false, "discarded"), false) } }

        it "isn't a bug: a pruned rewrite was never disproved" do
          expect(report["rule_bugs"]).to eq([])
        end
      end

      context "with rewrites the LLM and the operator made that were disproved" do
        let(:outcome) do
          with_rewrite do |store|
            rule_made(store, 2, tested(false, "null_semantics", "S3"), false)
            store.write("rewrite_2", "sql" => "SELECT 2", "source" => "llm")
            rule_made(store, 3, tested(true), true)
            store.write("rewrite_3", "sql" => "SELECT 3", "source" => "operator")
            store.write("result_comparison", "verdicts" => {}, "discarded" => ["rewrite_3"], "partial_count" => 0)
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
      "covered_by" => "orders_created_at_id_idx", "makes_redundant" => []
    )
    expect(report["indexes"]["quaack_b"]).to include("covered_by" => nil,
                                                     "makes_redundant" => ["orders_created_at_id_idx"])
    expect(report["indexes"]["quaack_c"]["ddl"]).to include("note = ?")
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
    rewrite = report["candidates"].find { it["label"] == "rewrite_1:none" }
    expect(rewrite["plan"].first).to include("node" => "Index Scan", "index" => "orders_created_at_id_idx",
                                             "selectivity" => 0.005)
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

    def dedupe # rubocop:disable Metrics/MethodLength
      existing = "CREATE INDEX orders_created_at_id_idx ON public.orders USING btree (created_at, id)"
      { "proposals" => [], "set_aside" => [], "considered" => 3,
        "drops" => [{ "candidate" => plain("CREATE INDEX ON public.orders USING btree (created_at)"),
                      "reason" => "covered_by_existing",
                      "covered_by" => { "existing" => "orders_created_at_id_idx", "definition" => plain(existing) } },
                    { "candidate" => plain("CREATE INDEX ON public.orders USING btree (created_at) " \
                                           "WHERE note = '#{sentinel}'"),
                      "reason" => "covered_by_existing",
                      "covered_by" => { "existing" => "orders_created_at_id_idx", "definition" => plain(existing) } },
                    { "candidate" => plain("CREATE INDEX ON public.orders USING btree (id)"),
                      "reason" => "duplicate", "covered_by" => nil }] }
    end

    def populate_negative(store) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      populate(store)
      store.write("selection", "top" => [], "infinite_sets" => [],
                               "excluded" => { "rewrite_1:none" => "not_better", "rewrite_6:none" => "result_mismatch",
                                               "rewrite_2:none" => "not_better",
                                               # No rewrite_survived_7, so it never survived.
                                               "rewrite_7:none" => "footprint_tie" })
      store.write("rewrite_2", "sql" => "SELECT 1")
      store.write("rewrite_tested_2", "passed" => false, "scenario" => "S3", "rule" => "null_semantics",
                                      "untested" => 0, "untested_atoms" => [])
      store.write("rewrite_survived_2", "survived" => false)
      store.write("rewrite_3", "sql" => "SELECT 2", "source" => "llm", "transformation" => sentinel)
      store.write("rewrite_tested_3", "passed" => true, "scenario" => nil, "rule" => nil, "untested" => 0,
                                      "untested_atoms" => [])
      store.write("rewrite_round_3", "round" => 2, "evidence" => true)
      store.write("rewrite_survived_3", "survived" => false)
      # rewrite_4 passed step 9, and step 10 disproved it, but its round
      # entry is missing. rewrite_5 was never stored, so rewrite_6 sits
      # past a gap. It survived steps 9 and 10, and 14c knocked it out.
      store.write("rewrite_4", "sql" => "SELECT 4")
      store.write("rewrite_tested_4", "passed" => true, "scenario" => nil, "rule" => nil, "untested" => 0,
                                      "untested_atoms" => [])
      store.write("rewrite_survived_4", "survived" => false)
      store.write("rewrite_6", "sql" => "SELECT 6")
      store.write("rewrite_tested_6", "passed" => false, "scenario" => "S1", "rule" => "duplicates",
                                      "untested" => 0, "untested_atoms" => [])
      store.write("rewrite_survived_6", "survived" => false)
      # btree (status) is unused but set aside for 12a (20260927-11), so it isn't declined.
      results = [result("btree (status)", used: false),
                 result("btree (note) WHERE note = '#{sentinel}'", used: false),
                 result("gin (note)", used: false, refusal: { "rule" => "hypopg_refused", "sqlstate" => "0A000" }),
                 result("btree (id, note)", used: true)]
      store.write("index_search_original",
                  "dedupe" => dedupe, "llm_results" => [], "results" => results,
                  "set_aside" => [plain("CREATE INDEX ON public.orders USING btree (status)")])
    end

    let(:outcome) do
      store = Quaack::Enclave::Store.create(base: quaacks.store_base)
      populate_negative(store)
      quaacks.run("report-payload", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })
    end

    it "says which rewrites were disproved, by which step 9 scenario or step 10 round, and where each came from" do
      unknown = { "source" => nil, "rules" => nil }
      expect(report["negative"]["disproved"]).to eq(
        [{ "rewrite" => "rewrite_2", "step" => "step9", "rule" => "null_semantics", "scenario" => "S3",
           "round" => nil, **unknown },
         { "rewrite" => "rewrite_3", "step" => "step10", "rule" => nil, "scenario" => nil, "round" => 2,
           "source" => "llm", "rules" => nil },
         { "rewrite" => "rewrite_4", "step" => "step10", "rule" => nil, "scenario" => nil, "round" => nil, **unknown },
         { "rewrite" => "rewrite_6", "step" => "step9", "rule" => "duplicates", "scenario" => "S1",
           "round" => nil, **unknown }]
      )
    end

    it "says which indexes the planner declined, and why, with redacted DDL" do
      expect(report["negative"]["declined"]).to eq(
        [{ "search" => "original", "ddl" => "CREATE INDEX ON public.orders USING btree (note) WHERE note = ?",
           "reason" => "unused", "sqlstate" => nil },
         { "search" => "original", "ddl" => "CREATE INDEX ON public.orders USING gin (note)",
           "reason" => "hypopg_refused", "sqlstate" => "0A000" }]
      )
    end

    it "says which proposed indexes already existed" do
      expect(report["negative"]["existing"]).to eq(
        [{ "search" => "original", "ddl" => "CREATE INDEX ON public.orders USING btree (created_at)",
           "covered_by" => "orders_created_at_id_idx" },
         { "search" => "original", "ddl" => "CREATE INDEX ON public.orders USING btree (created_at) WHERE note = ?",
           "covered_by" => "orders_created_at_id_idx" }]
      )
    end

    it "says which rewrites passed steps 9 and 10 but minimax or 14c knocked out" do
      expect(report["negative"]["knocked_out"]).to eq([{ "label" => "rewrite_1:none", "reason" => "not_better",
                                                         "source" => "rule", "rules" => ["key_in_self_join"] }])
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
