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
    TestPgDump.bin
  rescue TestPgDump::NotFound => e
    it("replays the prompt pack, with a pg_dump of the test server's major version") { raise e }
  else
    class_exec(&)
  end

  replays do
    PromptPack::QUERIES.each do |query|
      described_class.variants(query.name).each do |variant|
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

          it "sends each replayed ask the prompt its reply answered" do
            expect(outcome.drift).to be_empty
          end

          it "never reports the subtly wrong rewrite as a winning fix" do
            # Disproved at step 9 or 10: never marked for step 11, and so
            # never measured or ranked. The report sends it with that fate.
            labels = outcome.report ? (outcome.report["top"] + outcome.report["labels"]).map { it["label"] } : []
            fates = outcome.report ? outcome.report["rewrites"].to_h { [it["rewrite"], it["fate"]] } : {}
            outcome.wrong.each do |n|
              expect(outcome.entries["rewrite_step11_#{n}"]).to be(false)
              expect(labels.grep(/\Arewrite_#{n}:/)).to be_empty
              expect(fates["rewrite_#{n}"]).to eq("step9_disproved").or eq("step10_disproved") if outcome.report
            end
          end

          it "finds the wrong rewrite whenever the 6a reply holds the wrong condition" do
            wrong_condition = outcome.rewrites_text.to_s.include?(described_class.condition(query))
            expect(outcome.wrong).not_to be_empty if wrong_condition
          end
        end
      end
    end

    # Task 20261001-23: DESIGN.md 6c end to end. The rule's rewrite is the
    # run's only one, since every LLM ask gets an empty answer.
    describe "a query the key_in_self_join rule fires on" do
      let(:outcome) { described_class.cached(TestPostgres.server, described_class::RULE_QUERY, described_class::EMPTY) }
      let(:rewrite) { outcome.report["rewrites"].find { it["rewrite"] == "rewrite_1" } }
      let(:ranked) { outcome.report["top"].map { it["label"] }.grep(/\Arewrite_1:/) }

      it "applies the rules before 6a, storing the rule's rewrite, and ends in a report" do
        expect(outcome.error).to be_nil
        expect(outcome.entries).to include("rewrite_rules_applied" => true, "rewrite_1" => true,
                                           "rewrites_generated" => true, "rewrite_step11_1" => true)
        expect(outcome.entries).not_to include("rewrite_2")
        expect(outcome.log).to include("6a-1: empty answer (no reply)")
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

      it "records the 6c burndown, and flags no rule bug, since no test disproved the rewrite" do
        expect(outcome.report["burndown"]["stages"]["6c"]["rewrites"])
          .to include("added" => { "key_in_self_join" => 1 }, "out" => 1)
        expect(outcome.report["rule_bugs"]).to eq([])
      end

      it "shows the source and the 6c row in the report file `quaack run` writes" do
        expect(outcome.html).to include("Source: made by QUAACK&#39;s rule key_in_self_join.")
        expect(outcome.html).to include("<tr><td>6c</td><td>0</td><td>key_in_self_join: 1</td>")
        expect(outcome.html).not_to include("quaack-bugs")
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

      it "read a prose-wrapped 6a reply, and step 10 disproves its wrong rewrite with the replayed 10a-4" do
        outcome = run("group_having")
        expect(outcome.log).to include("6a-1: replayed", "10a-4: replayed", "step11-5a-5-1: replayed",
                                       "10a-1: empty answer (no reply)", "10a-7: empty answer (no reply)")
        # 10a-4 disproves in round one, so the operator rewrite's rounds are
        # still 10a-7 to 10a-9, as the pack numbers them.
        expect(outcome.log.grep(/\A10a-[56]:/)).to be_empty
        expect(outcome.wrong).to eq([2])
        expect(outcome.entries).to include("rewrite_step11_1" => true, "rewrite_step11_2" => false)
      end

      it "load a 10a-4 that sets GENERATED ALWAYS ids with OVERRIDING SYSTEM VALUE, and it disproves (orm_join)" do
        outcome = run("orm_join")
        expect(outcome.log).to include("6a-1: replayed", "10a-4: replayed")
        expect(outcome.wrong).to eq([2])
        expect(outcome.entries).to include("rewrite_step11_1" => true, "rewrite_step11_2" => false)
      end

      it "refuse a wrong-shape reply cleanly as llm_bad_response" do
        outcome = run("correlated_exists")
        expect(outcome.log).to eq(["5a-5-1: replayed"])
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

    it "names 10a asks by rewrite and round, three numbers per rewrite, so an early disproof shifts nothing" do
      replies = PipelineReplay::Replies.new("q", variant, roots: [])
      replies.for("6a", body("x"))
      # Rewrite 1 runs all three rounds, rewrite 2 is disproved in round
      # one, and rewrite 3 is disproved in round two.
      [1, 2, 3, 1, 1, 2].each { replies.for("10a", body("x", it)) }
      expect(replies.log.map { it.split(":").first }).to eq(%w[6a-1 10a-1 10a-2 10a-3 10a-4 10a-7 10a-8])
    end

    it "checks a reply's prompt against the prompt.md in the root it came from, then the corpus" do
      Dir.mktmpdir do |root|
        sent = PromptPack.prompt(PipelineReplay::Replies::Ask.new(body("x")))
        save(root, "6a-1", prompt: sent)
        save(root, "10a-1", prompt: sent.sub("# System\n\nS", "# System\n\nchanged"))
        replies = PipelineReplay::Replies.new("q", variant, roots: [root])
        replies.for("6a", body("x"))
        replies.for("10a", body("x"))
        expect(replies.drift).to eq(["10a-1: the system prompt sent differs from #{File.join(root, "q", "10a-1",
                                                                                             "prompt.md")}"])
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

    it "finds nothing when there's no 6a reply, or it doesn't parse" do
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
end
