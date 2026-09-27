# frozen_string_literal: true

require_relative "spec_helper"

# Task 20260922-65: each prompt-pack query through intake, setup, and the
# full driver Pipeline on a throwaway harness Postgres, once per replay
# variant (PipelineReplay). Replies come from spec/fixtures/llm_corpus and
# the planted spec/fixtures/pipeline_replay, and go through the real LLM
# client as raw text. Each run happens once and its examples share it.
RSpec.describe PipelineReplay do
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

        it "sends each replayed ask the prompt its reply answered" do
          expect(outcome.drift).to be_empty
        end

        it "never reports the subtly wrong rewrite as a winning fix" do
          wrong = query.bug.last.delete_prefix(query.bug.first).delete_prefix(" AND ")
          candidates = outcome.report ? outcome.report.fetch("candidates") : []
          winners = candidates.select { |c| outcome.report.fetch("top").any? { it["label"] == c["label"] } }
          expect(winners.map { it["sql"] }).to all(satisfy { !it.include?(wrong) })
        end
      end
    end
  end

  describe "the planted replies" do
    def run(name)
      query = PromptPack::QUERIES.find { it.name == name }
      variant = described_class::Variant.new(llm: "planted", k: 1)
      described_class.cached(TestPostgres.server, query, variant)
    end

    it "are found as a variant" do
      expect(described_class.variants("group_having")).to include(described_class::Variant.new(llm: "planted", k: 1))
    end

    it "fall back to all empty answers for a query with no replies" do
      expect(described_class.variants("orm_join")).to eq([described_class::EMPTY])
    end

    it "read a prose-wrapped 6a reply, and step 10 disproves its wrong rewrite with the replayed 10a-4" do
      outcome = run("group_having")
      expect(outcome.log).to include("6a-1: replayed", "10a-4: replayed", "step11-5a-5-1: replayed",
                                     "10a-1: empty answer (no reply)")
      expect(outcome.entries).to include("rewrite_step11_1" => true, "rewrite_step11_2" => false)
    end

    it "refuse a wrong-shape reply cleanly as llm_bad_response" do
      outcome = run("correlated_exists")
      expect(outcome.log).to eq(["5a-5-1: replayed"])
      expect(outcome.error).to have_attributes(class: Quaack::Driver::LLM::Error, rule: "llm_bad_response")
    end
  end
end
