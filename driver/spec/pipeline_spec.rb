# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/pipeline"
require_relative "support/fake_llm"

RSpec.describe Quaack::Driver::Pipeline do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:payload) { { "type" => "index_payload", "query" => "SELECT 1", "mechanical_results" => {} } }
  let(:feedback) { { "type" => "index_feedback", "revise" => false, "refined" => false } }
  let(:entries) do
    { "index_search_original" => false, "index_generated_original" => false, "index_ranking_original" => false,
      "rewrites_generated" => true }
  end

  # Stands in for the ssh transport, at the edge: records each call and
  # answers with the enclave's messages for that subcommand.
  let(:transport) do
    replies = { "status" => [{ "type" => "status", "entries" => entries }], "index-payload" => [payload],
                "index-feedback" => [feedback],
                "index-test" => [{ "type" => "index_outcome", "index" => 1, "outcome" => "accepted" }] }
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        Data.define(:messages).new(messages: replies.fetch(subcommand, []))
      end
    end.new
  end

  def run = described_class.new(transport:, client:, run_id: "RUN").run
  def subcommands = transport.calls.map(&:first)

  it "runs step 5 in the README's order: plan gate and 5a-1 to 5a-4, 5a-5, 5a-6, then 5a-7" do
    fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON public.t (a)"] })

    run

    expect(subcommands).to eq(%w[status index-search index-payload index-test index-feedback index-rank status])
    expect(transport.calls.map { it.last[:args] }.uniq).to eq([{ run: "RUN" }, { run: "RUN", search: "original" }])
    expect(fake.asks.map(&:step)).to eq(["5a-5"])
  end

  it "runs the refinement round when the feedback asks for one" do
    fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
    fake.reply("5a-6", { "indexes" => ["CREATE INDEX ON public.t (b)"] })
    feedback.merge!("revise" => true, "candidates" => [{ "shortfall" => "unused" }], "baseline" => {})

    run

    expect(subcommands)
      .to eq(%w[status index-search index-payload index-test index-feedback index-test index-rank status])
    expect(transport.calls[5].last[:args]).to include(round: "refinement")
  end

  it "records 5a-5 as done with an empty index-test when the LLM proposes nothing" do
    fake.reply("5a-5", { "indexes" => [] })

    run

    expect(transport.calls.select { it.first == "index-test" }.map { it.last[:input] }).to eq([{ "ddls" => [] }])
  end

  it "resumes, skipping the steps whose outputs are already in the store" do
    entries.merge!("index_search_original" => true, "index_generated_original" => true)

    run

    expect(subcommands).to eq(%w[status index-feedback index-rank status])
    expect(fake.asks).to eq([])

    entries["index_ranking_original"] = true
    transport.calls.clear
    run
    expect(subcommands).to eq(%w[status index-feedback status])
  end

  describe "step 6a and step 8" do
    let(:done) do
      { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true }
    end
    let(:rewrite_payload) { { "type" => "rewrite_payload", "query" => "SELECT 1" } }
    let(:statuses) { [] }

    # The status replies in order: the first for the run, the rest after 6a.
    let(:transport) do
      replies = { "index-payload" => [payload], "index-feedback" => [feedback], "rewrite-payload" => [rewrite_payload],
                  "rewrite-check" => [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted" }] }
      queue = statuses
      Class.new do
        attr_reader :calls

        define_method(:initialize) { @calls = [] }

        define_method(:call) do |subcommand, **options|
          @calls << [subcommand, options]
          messages = if subcommand == "status"
                       [{ "type" => "status", "entries" => queue.size > 1 ? queue.shift : queue.first }]
                     else
                       replies.fetch(subcommand, [])
                     end
          Data.define(:messages).new(messages:)
        end
      end.new
    end

    # A stored rewrite's status entries, with the named outputs done.
    def rewrite(number, *outputs)
      %w[index_search_rewrite_ index_ranking_rewrite_ rewrite_pruned_]
        .to_h { ["#{it}#{number}", outputs.include?(it)] }
        .merge("rewrite_#{number}" => true, "rewrite_survived_#{number}" => true)
    end

    it "generates rewrites (6a) after step 5, then runs step 8 on each stored rewrite" do
      fake.reply("6a", { "rewrites" => [{ "sql" => "SELECT 2", "transformation" => "t", "assumptions" => [] }] })
      statuses.push(done.merge("rewrites_generated" => false),
                    done.merge("rewrites_generated" => true, **rewrite(1), **rewrite(2)))

      run

      expect(subcommands.drop(2)).to eq(%w[rewrite-payload rewrite-check status] +
                                        (%w[index-search index-rank rewrite-prune] * 2) + %w[status status])
      expect(transport.calls.last(8).first(6).map { it.last[:args][:search] })
        .to eq(%w[rewrite_1 rewrite_1 rewrite_1 rewrite_2 rewrite_2 rewrite_2])
      expect(fake.asks.map(&:step)).to eq(["6a"])
    end

    it "resumes, skipping 6a and the step 8 outputs already stored" do
      statuses.push(done.merge("rewrites_generated" => true,
                               **rewrite(1, "index_search_rewrite_", "index_ranking_rewrite_", "rewrite_pruned_"),
                               **rewrite(2, "index_search_rewrite_")))

      run

      expect(subcommands.drop(2)).to eq(%w[index-rank rewrite-prune status])
      expect(transport.calls[-2].last[:args]).to eq(run: "RUN", search: "rewrite_2")
      expect(fake.asks).to eq([])
    end
  end

  describe "step 11" do
    let(:step8) { %w[index_search_rewrite_ index_ranking_rewrite_ rewrite_pruned_] }

    # A rewrite through step 8, with its step 11 status.
    def rewrite(number, step11:, generated: false, ranked: false)
      step8.to_h { ["#{it}#{number}", true] }
           .merge("rewrite_#{number}" => true, "rewrite_survived_#{number}" => true,
                  "rewrite_step11_#{number}" => step11,
                  "index_generated_rewrite_#{number}" => generated, "index_llm_ranked_rewrite_#{number}" => ranked)
    end

    def searched = transport.calls.drop(1).map { [it.first, it.last[:args][:search]] }

    it "runs 5a-5, 5a-6, and 5a-7 on each rewrite status marks for step 11, after step 8" do
      entries.merge!("index_search_original" => true, "index_generated_original" => true,
                     "index_ranking_original" => true, **rewrite(1, step11: false), **rewrite(2, step11: true))
      fake.reply("5a-5", { "indexes" => ["CREATE INDEX ON public.t (a)"] })

      run

      expect(searched).to eq([%w[index-feedback original], ["status", nil],
                              %w[index-payload rewrite_2], %w[index-test rewrite_2], %w[index-feedback rewrite_2],
                              %w[index-rank rewrite_2]])
      expect(fake.asks.map(&:step)).to eq(["5a-5"])
    end

    it "resumes, skipping 5a-5 and the second 5a-7 once they ran" do
      entries.merge!("index_search_original" => true, "index_generated_original" => true,
                     "index_ranking_original" => true, **rewrite(1, step11: true, generated: true),
                     **rewrite(2, step11: true, generated: true, ranked: true))

      run

      expect(searched.drop(2)).to eq([%w[index-feedback rewrite_1], %w[index-rank rewrite_1],
                                      %w[index-feedback rewrite_2]])
      expect(fake.asks).to eq([])
    end
  end

  describe "steps 9 and 10" do
    let(:done) do
      { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
        "rewrites_generated" => true }
    end
    let(:status) { done }
    let(:tests) { [] }
    let(:outcome) do
      { "type" => "counterexample_round", "match" => true, "rule" => nil, "covered" => [], "refused" => [] }
    end
    let(:counter_payload) { { "type" => "counterexample_payload", "original" => "SELECT 1" } }

    let(:transport) do
      replies = { "index-payload" => [payload], "index-feedback" => [feedback],
                  "counterexample-payload" => [counter_payload], "counterexample-round" => [outcome] }
      queue = tests
      state = status
      Class.new do
        attr_reader :calls

        define_method(:initialize) { @calls = [] }

        define_method(:call) do |subcommand, **options|
          @calls << [subcommand, options]
          messages = case subcommand
                     when "status" then [{ "type" => "status", "entries" => state }]
                     when "rewrite-test" then [{ "type" => "rewrite_test", "passed" => queue.shift }]
                     else replies.fetch(subcommand, [])
                     end
          Data.define(:messages).new(messages:)
        end
      end.new
    end

    def rewrite(number, tested: false, survived: false)
      %w[index_search_rewrite_ index_ranking_rewrite_ rewrite_pruned_].to_h { ["#{it}#{number}", true] }
                                                                      .merge("rewrite_#{number}" => true,
                                                                             "rewrite_tested_#{number}" => tested,
                                                                             "rewrite_survived_#{number}" => survived)
    end

    def ninth_on = subcommands.drop(2).reject { it == "status" }

    it "runs step 9 on each rewrite, then three 10a rounds on the one that passed, numbering them" do
      status.merge!(rewrite(1), rewrite(2))
      tests.push(false, true)
      3.times { fake.reply("10a", { "inserts" => ["INSERT INTO public.t (a) VALUES ($1)"] }) }

      run

      expect(ninth_on).to eq(%w[rewrite-test rewrite-test counterexample-payload] + (["counterexample-round"] * 3))
      rounds = transport.calls.select { it.first == "counterexample-round" }
      expect(rounds.map { it.last[:args] }).to eq([1, 2, 3].map { { run: "RUN", search: "rewrite_2", round: it } })
      expect(rounds.first.last[:input]).to eq("inserts" => ["INSERT INTO public.t (a) VALUES ($1)"])
      expect(fake.asks.first.body[:messages].first[:content]).to include(%("original":"SELECT 1"))
    end

    it "fails with a clean rule when a reply lacks the message it expects" do
      status.merge!(rewrite(1))
      replies = { "status" => [{ "type" => "status", "entries" => status }], "index-feedback" => [feedback] }
      transport.define_singleton_method(:call) do |subcommand, **|
        Data.define(:messages).new(messages: replies.fetch(subcommand, []))
      end

      expect { run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("no_rewrite_test") }

      status.merge!(rewrite(1, tested: true))
      expect { run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("no_counterexample_payload") }
    end

    it "resumes: skips a rewrite that's decided, and step 9 for one already tested" do
      status.merge!(rewrite(1, tested: true, survived: true), rewrite(2, tested: true))
      3.times { fake.reply("10a", { "inserts" => [] }) }

      run

      expect(ninth_on).to eq(%w[counterexample-payload] + (["counterexample-round"] * 3))
    end
  end
end
