# frozen_string_literal: true

require_relative "spec_helper"

# Task 20260922-65: each prompt-pack query through intake, setup, and the
# full driver Pipeline on a throwaway harness Postgres, once per replay
# variant (PipelineReplay). Replies come from spec/fixtures/llm_corpus and
# the planted spec/fixtures/pipeline_replay, and go through the real LLM
# client as raw text. Each run happens once and its examples share it.
RSpec.describe PipelineReplay do
  # Every run's schema-dump needs a pg_dump of the test server's major
  # version (TestPgDump). It's looked for once, as this file loads. Without
  # one, the runs below are one failing example that says what to install
  # or set, rather than every run failing on its own.
  def self.replays(&)
    TestPgDump.examples(self, "replays the prompt pack, with a pg_dump of the test server's major version", &)
  end

  # The stages whose "in" isn't what the recorded stages before them left
  # in the pipe, as "name: in N, in the pipe M". Rows are as Report's Stages
  # gives them. A stage that adds records in 0 and starts from what's there.
  def burndown_gaps(rows)
    running = 0
    rows.filter_map do |name, record, _|
      next unless record&.values_at("in", "out")&.all?

      gap = "#{name}: in #{record["in"]}, in the pipe #{running}" unless burndown_joins?(record, running)
      running += record["out"] - record["in"]
      gap
    end
  end

  # Whether the record's in is the width in the pipe. A stage that adds, or
  # that ran on nothing and sent nothing (a skipped round), has in 0.
  def burndown_joins?(record, running)
    return true if record["in"] == running

    record["in"].zero? && (!record["added"].to_h.empty? || record["out"].zero?)
  end

  replays do
    PromptPack::QUERIES.each do |query|
      described_class.selected_variants(query.name, full: FullReplay.on?).each do |variant|
        context "#{query.name}, replaying #{variant}" do
          let(:outcome) { described_class.cached(TestPostgres.server, query, variant) }

          it "ends in a report or a clean refusal" do
            if outcome.error
              expect(outcome.error).to be_a(Quaack::Driver::LLM::Error).or be_a(Quaack::Driver::EnclaveError)
            else
              expect(outcome.report).to include("type" => "report")
            end
          end

          it "tears the run down when it ends, deleting its store" do
            expect(outcome.store_left).to be(false)
            expect(outcome.teardown).to start_with("quaack: deleted the store for run ")
          end

          # Task 20261001-20.
          it "records every index stage of the original query's search when it ends in a report" do
            stages = outcome.report ? outcome.report["burndown"]["stages"] : {}
            missing = Quaack::Driver::Report::Words::INDEX_STAGES.keys.reject { stages.dig(it, "original") }
            expect(missing).to eq([]) if outcome.report
          end

          # Task 20261009-4: the burndown funnels draw what's in the pipe, so a
          # stage's count of what came in is what the stages before it left.
          # A stage that adds (in 0) starts from the width before it.
          it "counts what each burndown stage came in with as what the stages before it left" do
            next unless outcome.report

            view = Quaack::Driver::Report::View.new(outcome.report, "run")
            gaps = %i[index_rows rewrite_rows rewrite_index_rows].flat_map { burndown_gaps(view.public_send(it)) }
            expect(gaps).to eq([])
          end

          it "sends each replayed ask the prompt its reply answered" do
            expect(outcome.drift).to be_empty
          end

          it "never reports the subtly wrong rewrite as a winning fix" do
            # Disproved at rewrite-test or counterexamples: never marked for rewrite-index-ideas, and so
            # never measured or ranked. The report sends it with that fate.
            labels = outcome.report ? (outcome.report["top"] + outcome.report["labels"]).map { it["label"] } : []
            fates = outcome.report ? outcome.report["rewrites"].to_h { [it["rewrite"], it["fate"]] } : {}
            outcome.wrong.each do |n|
              expect(outcome.entries["rewrite_index_ideas_#{n}"]).to be(false)
              expect(labels.grep(/\Arewrite_#{n}:/)).to be_empty
              if outcome.report
                expect(fates["rewrite_#{n}"]).to eq("rewrite_test_disproved").or eq("counterexamples_disproved")
              end
            end
          end

          it "finds the wrong rewrite whenever the llm-rewrites reply holds the wrong condition" do
            wrong_condition = outcome.rewrites_text.to_s.include?(described_class.condition(query))
            if wrong_condition
              expect(outcome.wrong).not_to be_empty
            else
              expect(outcome.wrong).to be_empty
            end
          end
        end
      end
    end

    # Task 20261001-23: DESIGN.md's rewrite-rules end to end. The rule's rewrite is the
    # run's only one, since every LLM ask gets an empty answer.
    describe "a query the key_in_self_join rule fires on" do
      let(:outcome) { described_class.cached(TestPostgres.server, described_class::RULE_QUERY, described_class::EMPTY) }
      let(:rewrite) { outcome.report["rewrites"].find { it["rewrite"] == "rewrite_1" } }
      let(:ranked) { outcome.report["top"].map { it["label"] }.grep(/\Arewrite_1:/) }

      # Task 20261009-4: the rule's rewrite goes through assumption-check and
      # plan-pruning counted, so each stage starts as wide as the last ended.
      it "counts the rule's rewrite in every stage after rewrite-rules, so the stages join up" do
        view = Quaack::Driver::Report::View.new(outcome.report, "run")
        expect(burndown_gaps(view.rewrite_rows)).to eq([])
        expect(view.rewrite_rows.assoc("Checking what each rewrite assumes")[1].values_at("in", "out")).to eq([1, 1])
      end

      it "applies the rules before llm-rewrites, storing the rule's rewrite, and ends in a report" do
        expect(outcome.error).to be_nil
        expect(outcome.entries).to include("rewrite_rules_applied" => true, "rewrite_1" => true,
                                           "rewrites_generated" => true, "rewrite_index_ideas_1" => true)
        expect(outcome.entries).not_to include("rewrite_2")
        expect(outcome.log).to include("llm-rewrites-1: empty answer (no reply)")
        expect(outcome.log.grep(/replayed\z/)).to be_empty
      end

      it "ranks the rule's rewrite in the report, with its source and its rule" do
        expect(ranked).not_to be_empty
        expect(outcome.report["rewrites"].size).to eq(1)
        expect(rewrite).to include("source" => "rule", "rules" => ["key_in_self_join"], "fate" => "ranked")
        expect(rewrite["sql"]).to eq("SELECT o.id, o.total_cents FROM public.orders o WHERE (o.created_at >= $1 " \
                                     "AND o.created_at < $2) OR o.status = $3 ORDER BY o.id")
      end

      it "sends the original query, and every measured label with its blocks and its indexes" do
        expect(outcome.report["original_sql"])
          .to eq("SELECT o.id, o.total_cents FROM public.orders o WHERE o.id IN (SELECT o2.id FROM public.orders o2 " \
                 "WHERE o2.created_at >= $1 AND o2.created_at < $2 UNION ALL SELECT o3.id FROM public.orders o3 " \
                 "WHERE o3.status = $3) ORDER BY o.id")
        labels = outcome.report["labels"]
        expect(labels.map { it["label"] }).to include(*outcome.report["top"].map { it["label"] })
        expect(labels.map { it["label"] }).to include("rewrite_1:none")
        expect(labels.reject { it["timed_out"] }.map { it.dig("measurements", "slow", "total_blocks") })
          .to all(be_a(Integer))
        built = outcome.report["indexes"].keys
        expect(labels.flat_map { it["indexes"] } - built).to be_empty
      end

      it "records the rewrite-rules burndown, and flags no rule bug, since no test disproved the rewrite" do
        expect(outcome.report["burndown"]["stages"]["rewrite-rules"]["rewrites"])
          .to include("added" => { "key_in_self_join" => 1 }, "out" => 1)
        expect(outcome.report["rule_bugs"]).to eq([])
      end

      # Task 20261001-19: every rewrite stage the rule's rewrite went
      # through, each counting it once, and the work totals.
      it "records the rule's rewrite going through every later rewrite stage once, and the work totals" do
        stages = outcome.report["burndown"]["stages"]
        went_on = { "in" => 1, "out" => 1 }
        expect(stages.slice("plan-pruning", "rewrite-test", "counterexamples").transform_values(&:keys))
          .to eq("plan-pruning" => ["rewrite_1"], "rewrite-test" => ["rewrite_1"], "counterexamples" => ["rewrite_1"])
        %w[plan-pruning rewrite-test counterexamples].each { expect(stages[it]["rewrite_1"]).to include(went_on) }
        %w[rewrite-index-ideas measurement].each { expect(stages[it]["rewrites"]).to include(went_on) }
        expect(outcome.report["burndown"]["totals"].slice("indexes_built", "measurement_runs", "fixture_loads"))
          .to match("indexes_built" => be_positive, "measurement_runs" => be_positive, "fixture_loads" => be_positive)
      end

      # Task 20261001-20: the original query's index search, its LLM
      # rounds, and its ranking, and the rewrite's own index search.
      it "records the original's and the rewrite's index stages" do
        stages = outcome.report["burndown"]["stages"]
        index_stages = Quaack::Driver::Report::Words::INDEX_STAGES.keys
        expect(index_stages.reject { stages.dig(it, "original") }).to eq([])
        expect(stages.dig("index-from-query", "original", "added")).to include("generator_one" => be_positive)
        expect(stages.dig("llm-index-ideas", "original")).to include("added" => { "llm" => 0 }, "out" => 0)
        expect(stages.dig("llm-index-refine", "original", "extra")).to eq("no_ideas_tested" => 1)
        expect(stages.dig("index-rank", "original")).to include("out" => be_positive)
        expect(index_stages.reject { stages.dig(it, "rewrite_1") }).to eq([])
      end

      it "shows the source and the rewrite-rules row in the report file `quaack run` writes" do
        expect(outcome.html).to include(
          "Where it came from: made by QUAACK&#39;s own rewrite rule <a href=\"https://github.com/benchub/quaack/" \
          "blob/main/docs/transforms/key_in_self_join.md\" target=\"_blank\" rel=\"noopener\">key_in_self_join</a>."
        )
        expect(outcome.html).to include("Rewrites from QUAACK&#39;s own rules</th>" \
                                        '<td class="num">0</td><td>by the rule key_in_self_join: 1</td>')
        expect(outcome.html).to match(/<tr title="[^"]+"><th scope="row">Rewrites from QUAACK&#39;s own rules/)
        expect(outcome.html).not_to include('id="quaack-bugs"')
      end

      it "keeps the query's literals out of the report" do
        text = JSON.generate(outcome.report) + outcome.html
        [PromptPack::SINCE, PromptPack::UNTIL].each { expect(text).not_to include(it[0, 10]) }
      end

      it "tears the run down when it ends, deleting its store" do
        expect(outcome.store_left).to be(false)
        expect(outcome.teardown).to start_with("quaack: deleted the store for run ")
      end
    end

    describe "the planted replies" do
      def run(name)
        query = PromptPack::QUERIES.find { it.name == name }
        variant = described_class::Variant.new(llm: "planted", k: 1)
        described_class.cached(TestPostgres.server, query, variant)
      end

      it "read a prose-wrapped llm-rewrites reply, and counterexamples disproves its wrong rewrite with the replayed " \
         "llm-counterexamples-4" do
        outcome = run("group_having")
        expect(outcome.log).to include("llm-rewrites-1: replayed", "llm-counterexamples-4: replayed",
                                       "rewrite-llm-index-ideas-1: replayed",
                                       "llm-counterexamples-1: empty answer (no reply)",
                                       "llm-counterexamples-7: empty answer (no reply)")
        # llm-counterexamples-4 disproves in round one, so the operator
        # rewrite's rounds are still llm-counterexamples-7 to -9, as the pack
        # numbers them.
        expect(outcome.log.grep(/\Allm-counterexamples-[56]:/)).to be_empty
        expect(outcome.wrong).to eq([2])
        expect(outcome.entries).to include("rewrite_index_ideas_1" => true, "rewrite_index_ideas_2" => false)
      end

      # Task 20261001-19: the LLM's and the operator's rewrites, each
      # counted at every rewrite stage it reached, the wrong one dropped.
      it "record every rewrite stage of a run with the LLM's and the operator's rewrites" do
        stages = run("group_having").report["burndown"]["stages"]
        rewrite_stages = Quaack::Driver::Report::Words::REWRITE_STAGES.keys - ["rewrite-rules"] +
                         Quaack::Driver::Report::Words::LATE_STAGES.keys
        expect(rewrite_stages - stages.keys).to eq([])
        expect(stages.dig("llm-rewrites", "rewrites", "added")).to include("llm" => be_positive)
        expect(stages.dig("operator-rewrites", "rewrites", "added")).to include("operator" => be_positive)
        expect(stages["rewrite-test"].keys + stages["counterexamples"].keys).to include("rewrite_2")
      end

      # Task 20261001-20: the replayed rewrite-llm-index-ideas-1's ideas,
      # counted at the rewrite's llm-index-ideas.
      it "record the LLM's index ideas for a rewrite" do
        stages = run("group_having").report["burndown"]["stages"]
        expect(stages.dig("llm-index-ideas", "rewrite_1", "added")).to match("llm" => be_positive)
        expect(stages.dig("llm-index-refine", "rewrite_1")).not_to be_nil
      end

      it "load an llm-counterexamples-4 that sets GENERATED ALWAYS ids with OVERRIDING SYSTEM VALUE, and it " \
         "disproves (orm_join)" do
        outcome = run("orm_join")
        expect(outcome.log).to include("llm-rewrites-1: replayed", "llm-counterexamples-4: replayed")
        expect(outcome.wrong).to eq([2])
        expect(outcome.entries).to include("rewrite_index_ideas_1" => true, "rewrite_index_ideas_2" => false)
      end

      it "refuse a wrong-shape reply cleanly as llm_bad_response" do
        outcome = run("correlated_exists")
        expect(outcome.log).to eq(["llm-index-ideas-1: replayed"])
        expect(outcome.error).to have_attributes(class: Quaack::Driver::LLM::Error, rule: "llm_bad_response")
      end
    end
  end

  # Task 20260927-24: Replies alone, over temporary reply roots.
  describe "Replies" do
    def body(text, rounds = 1)
      follow = [{ role: :assistant, content: "{}" }, { role: :user, content: "again" }]
      { system: "S", messages: [{ role: :user, content: text }] + (follow * (rounds - 1)) }
    end

    def save(root, dir, reply: "{}", prompt: nil)
      FileUtils.mkdir_p(File.join(root, "q", dir))
      File.write(File.join(root, "q", dir, "reply-t-1.md"), reply)
      File.write(File.join(root, "q", dir, "prompt.md"), prompt) if prompt
    end

    let(:variant) { PipelineReplay::Variant.new(llm: "t", k: 1) }

    it "names llm-counterexamples asks by rewrite and round, three per rewrite, so an early disproof shifts nothing" do
      replies = PipelineReplay::Replies.new("q", variant, roots: [])
      replies.for("llm-rewrites", body("x"))
      # Rewrite 1 runs all three rounds, rewrite 2 is disproved in round
      # one, and rewrite 3 is disproved in round two.
      [1, 2, 3, 1, 1, 2].each { replies.for("llm-counterexamples", body("x", it)) }
      names = replies.log.map { it.split(":").first }
      expect(names).to eq(%w[llm-rewrites-1 llm-counterexamples-1 llm-counterexamples-2 llm-counterexamples-3
                             llm-counterexamples-4 llm-counterexamples-7 llm-counterexamples-8])
    end

    it "checks a reply's prompt against the prompt.md in the root it came from, then the corpus" do
      Dir.mktmpdir do |root|
        sent = PromptPack.prompt(PipelineReplay::Replies::Ask.new(body("x")))
        save(root, "llm-rewrites-1", prompt: sent)
        save(root, "llm-counterexamples-1", prompt: sent.sub("# System\n\nS", "# System\n\nchanged"))
        replies = PipelineReplay::Replies.new("q", variant, roots: [root])
        replies.for("llm-rewrites", body("x"))
        replies.for("llm-counterexamples", body("x"))
        prompt = File.join(root, "q", "llm-counterexamples-1", "prompt.md")
        expect(replies.drift).to eq(["llm-counterexamples-1: the system prompt sent differs from #{prompt}"])
      end
    end
  end

  describe ".wrong" do
    let(:query) { PromptPack::QUERIES.find { it.name == "orm_join" } }

    it "reads the rewrites with the client's tolerant JSON parse, skipping a stray example object" do
      text = <<~TEXT
        For example, {"sql": "SELECT 1 WHERE u.name IS NOT NULL"} would be wrong. Here are mine:
        {"rewrites": [{"sql": "SELECT 1", "transformation": "t", "assumptions": []},
                      {"sql": "SELECT 2 WHERE u.name IS NOT NULL", "transformation": "t", "assumptions": []}]}
      TEXT
      expect(described_class.wrong(query, text)).to eq([2])
    end

    it "matches the wrong condition in a rewrite's sql, not in its other fields" do
      text = <<~TEXT
        {"rewrites": [{"sql": "SELECT 1", "transformation": "drops u.name IS NOT NULL", "assumptions": []}]}
      TEXT
      expect(described_class.wrong(query, text)).to eq([])
    end

    it "finds nothing when there's no llm-rewrites reply, or it doesn't parse" do
      expect([described_class.wrong(query, nil), described_class.wrong(query, "no json")]).to eq([[], []])
    end
  end

  describe "the planted replies" do
    it "are found as a variant" do
      expect(described_class.variants("group_having")).to include(described_class::Variant.new(llm: "planted", k: 1))
    end

    it "fall back to all empty answers for a query with no replies" do
      Dir.mktmpdir do |root|
        expect(described_class.variants("keyset_pagination", roots: [root])).to eq([described_class::EMPTY])
      end
    end
  end

  describe ".selected_variants" do
    it "keeps planted replies and the first recorded run of the first model in the per-commit replay" do
      variants = described_class.selected_variants("group_having")

      expect(variants).to eq(
        [
          described_class::Variant.new(llm: "claude", k: 1),
          described_class::Variant.new(llm: "planted", k: 1)
        ]
      )
    end

    it "keeps every variant in the full replay" do
      expect(described_class.selected_variants("group_having", full: true))
        .to eq(described_class.variants("group_having"))
    end

    it "fails instead of silently running no recorded examples in the per-commit replay" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "query", "llm-rewrites-1"))
        File.write(File.join(root, "query", "llm-rewrites-1", "reply-planted-1.md"), "{}")

        expect { described_class.selected_variants("query", roots: [root]) }
          .to raise_error(/no recorded replay variants for query/)
      end
    end

    it "fails instead of running the all-empty fallback for a query with no replies in the per-commit replay" do
      Dir.mktmpdir do |root|
        expect { described_class.selected_variants("query", roots: [root]) }
          .to raise_error(/no recorded replay variants for query/)
      end
    end
  end
end
