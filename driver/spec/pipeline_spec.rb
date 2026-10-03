# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/pipeline"
require "quaack/driver/transport/base"
require_relative "support/fake_llm"

# Steps 4b and 12a to 14d, all stored, for specs about other steps.
MEASURED = %w[arena_setup index_build baseline index_baseline candidate_runs minimax result_comparison
              selection].to_h { [it, true] }.freeze

# Builds a call's argv with the real Transport::Base, so a fake transport
# raises ArgumentError for args the enclave's CLI can't take, as the ssh
# transport would.
CHECK_ARGV = ->(subcommand, options) { Quaack::Driver::Transport::Base.new.send(:argv, subcommand, options.fetch(:args, {})) }

RSpec.describe Quaack::Driver::Pipeline do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:payload) { { "type" => "index_payload", "query" => "SELECT 1", "mechanical_results" => {} } }
  let(:feedback) { { "type" => "index_feedback", "revise" => false, "refined" => false } }
  let(:entries) do
    { "index_search_original" => false, "index_generated_original" => false, "index_ranking_original" => false,
      "rewrite_rules_applied" => true, "rewrites_generated" => true }.merge(MEASURED)
  end

  # Stands in for the ssh transport, at the edge: records each call and
  # answers with the enclave's messages for that subcommand. It checks
  # each call's args with CHECK_ARGV.
  # Status replies after the first, in order, when a spec needs status to
  # change during the run. Otherwise every status call answers entries.
  let(:later_statuses) { [] }

  let(:transport) do
    statuses = later_statuses
    replies = { "status" => [{ "type" => "status", "entries" => entries }], "index-payload" => [payload],
                "index-feedback" => [feedback],
                "index-test" => [{ "type" => "index_outcome", "index" => 1, "outcome" => "accepted" }] }
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |subcommand, **options|
        CHECK_ARGV.call(subcommand, options)
        first_status = @calls.none? { it.first == "status" }
        @calls << [subcommand, options]
        messages = if subcommand == "status" && !first_status && statuses.any?
                     [{ "type" => "status", "entries" => statuses.shift }]
                   else
                     replies.fetch(subcommand, [])
                   end
        Data.define(:messages).new(messages:)
      end
    end.new
  end

  def run = described_class.new(transport:, client:, run_id: "RUN").run
  def subcommands = transport.calls.map(&:first)

  it "runs step 5 in DESIGN.md's order: plan gate and 5a-1 to 5a-4, 5a-5, 5a-6, then 5a-7" do
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
      { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
        "rewrite_rules_applied" => true }.merge(MEASURED)
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

    def run_with(rewrites) = described_class.new(transport:, client:, run_id: "RUN", rewrites:).run

    describe "the mechanical rules (6c)" do
      let(:not_applied) { done.merge("rewrite_rules_applied" => false) }

      it "applies them before 6a, with no LLM call, then asks status once for what both stored" do
        fake.reply("6a", { "rewrites" => [] })
        statuses.push(not_applied.merge("rewrites_generated" => false),
                      done.merge("rewrites_generated" => true, **rewrite(1), **rewrite(2)))

        run

        expect(subcommands.drop(2)).to eq(%w[rewrite-rules rewrite-payload rewrite-check status] +
                                          (%w[index-search index-rank rewrite-prune] * 2) + %w[status status])
        expect(transport.calls[2]).to eq(["rewrite-rules", { args: { run: "RUN" } }])
        expect(fake.asks.map(&:step)).to eq(["6a"])
      end

      it "applies them on a run whose 6a already ran, with no payload and no LLM call, then runs step 8" do
        statuses.push(not_applied.merge("rewrites_generated" => true),
                      done.merge("rewrites_generated" => true, **rewrite(1)))

        run

        expect(subcommands.drop(2)).to eq(%w[rewrite-rules status index-search index-rank rewrite-prune status status])
        expect(fake.asks).to eq([])
      end

      it "applies them before step 7 when only the operator's rewrites are left to check" do
        fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })
        statuses.push(not_applied.merge("rewrites_generated" => true, "operator_rewrites_checked" => false),
                      done.merge("rewrites_generated" => true, "operator_rewrites_checked" => true))

        run_with(["SELECT 3"])

        expect(subcommands.drop(2)).to eq(%w[rewrite-rules rewrite-payload rewrite-check status status status])
        expect(fake.asks.map(&:step)).to eq(["step7"])
      end

      it "skips them once the store says they were applied" do
        statuses.push(done.merge("rewrites_generated" => true))

        run

        expect(subcommands).not_to include("rewrite-rules")
      end

      it "stops the run when the enclave refuses them" do
        statuses.push(not_applied.merge("rewrites_generated" => false))
        refusal = Quaack::Driver::EnclaveError.new(subcommand: "rewrite-rules", rule: "racetrack_missing")
        calls = transport.method(:call)
        transport.define_singleton_method(:call) do |subcommand, **options|
          subcommand == "rewrite-rules" ? raise(refusal) : calls.call(subcommand, **options)
        end

        expect { run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("racetrack_missing") }
        expect(subcommands).not_to include("rewrite-payload")
      end
    end

    it "checks the operator's rewrites (step 7) right after 6a, on the same payload, before step 8" do
      fake.reply("6a", { "rewrites" => [] })
      fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })
      statuses.push(done.merge("rewrites_generated" => false, "operator_rewrites_checked" => false),
                    done.merge("rewrites_generated" => true, "operator_rewrites_checked" => true, **rewrite(1)))

      run_with(["SELECT 3"])

      expect(subcommands.drop(2)).to eq(%w[rewrite-payload rewrite-check rewrite-check status
                                           index-search index-rank rewrite-prune status status])
      expect(transport.calls[4].last[:input]).to eq("rewrites" => [{ "sql" => "SELECT 3", "transformation" => "t",
                                                                     "assumptions" => [] }], "inferred" => true)
      expect(fake.asks.map(&:step)).to eq(%w[6a step7])
    end

    it "treats an empty rewrites file as no step 7: no payload, rewrite-check, or LLM call after 6a" do
      statuses.push(done.merge("rewrites_generated" => true, "operator_rewrites_checked" => false))

      run_with([])

      expect(subcommands.drop(2)).to eq(%w[status])
      expect(fake.asks).to eq([])
    end

    it "resumes after 6a with step 7, and skips step 7 once the store says it ran" do
      fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })
      statuses.push(done.merge("rewrites_generated" => true, "operator_rewrites_checked" => false),
                    done.merge("rewrites_generated" => true, "operator_rewrites_checked" => true))

      run_with(["SELECT 3"])
      expect(subcommands.drop(2)).to eq(%w[rewrite-payload rewrite-check status status status])

      transport.calls.clear
      run_with(["SELECT 3"])
      expect(subcommands.drop(2)).to eq(%w[status])
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

    it "asks status again for step 11, rather than trusting the entries from the start of the run" do
      entries.merge!("index_search_original" => true, "index_generated_original" => true,
                     "index_ranking_original" => true, **rewrite(1, step11: false, generated: true, ranked: true))
      later_statuses << entries.merge("rewrite_step11_1" => true)

      run

      expect(searched.drop(2)).to eq([%w[index-feedback rewrite_1]])
    end
  end

  describe "steps 9 and 10" do
    let(:done) do
      { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
        "rewrite_rules_applied" => true, "rewrites_generated" => true }.merge(MEASURED)
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
          CHECK_ARGV.call(subcommand, options)
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
      expect(rounds.map { it.last[:args] }).to eq([1, 2, 3].map { { run: "RUN", search: "rewrite_2", round: it.to_s } })
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

RSpec.describe Quaack::Driver::Pipeline, "steps 4b and 12a to 14d" do
  let(:done) do
    { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
      "rewrite_rules_applied" => true, "rewrites_generated" => true }
  end
  let(:chain) { %w[index-build baseline index-baseline candidate-runs minimax result-comparison selection] }
  let(:failing) { {} }
  let(:transport) do
    all = { "status" => [{ "type" => "status", "entries" => done }],
            "index-feedback" => [{ "type" => "index_feedback", "revise" => false }],
            "rewrite-test" => [{ "type" => "rewrite_test", "passed" => false }] }
    f = failing
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        raise f[subcommand] if f.key?(subcommand)

        Data.define(:messages).new(messages: all.fetch(subcommand, []))
      end
    end.new
  end

  def run = described_class.new(transport:, client: nil, run_id: "RUN").run

  it "runs arena-setup before steps 9 and 10, and 12a to 14d in order after step 11" do
    done.merge!("rewrite_1" => true, "index_search_rewrite_1" => true, "index_ranking_rewrite_1" => true,
                "rewrite_pruned_1" => true)

    run

    expect(transport.calls.map(&:first)).to eq(%w[status index-feedback arena-setup rewrite-test status] +
                                               chain)
    args = transport.calls.drop(2).map { it.last[:args] }
    expect(args.uniq).to eq([{ run: "RUN" }, { run: "RUN", search: "rewrite_1" }])
  end

  it "resumes: skips each step whose output is stored" do
    done.merge!("arena_setup" => true, "index_build" => true, "baseline" => true, "minimax" => true)

    run

    expect(transport.calls.map(&:first)).to eq(%w[status index-feedback status index-baseline candidate-runs
                                                  result-comparison selection])
  end

  it "stops the run at a failing step, with its rule" do
    failing["baseline"] = Quaack::Driver::EnclaveError.new(subcommand: "baseline", rule: "baseline_failed")

    expect { run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("baseline_failed") }
    expect(transport.calls.map(&:first).last(2)).to eq(%w[index-build baseline])
  end
end

RSpec.describe Quaack::Driver::Pipeline, "report stage" do
  let(:dir) { Dir.mktmpdir("quaack-report") }
  let(:out) { File.join(dir, "report.html") }
  let(:report) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => [], "indexes" => {}, "original_plan" => [],
      "timed_out_count" => 0 }
  end
  let(:done) do
    { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
      "rewrite_rules_applied" => true, "rewrites_generated" => true }.merge(MEASURED)
  end

  def transport(entries, replies = {})
    all = { "status" => [{ "type" => "status", "entries" => entries }],
            "index-feedback" => [{ "type" => "index_feedback", "revise" => false }] }.merge(replies)
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        Data.define(:messages).new(messages: all.fetch(subcommand, []))
      end
    end.new
  end

  after { FileUtils.rm_rf(dir) }

  def pipeline(transport) = described_class.new(transport:, client: nil, run_id: "RUN", out:)

  it "writes the report from report-payload last, once selection is stored, and returns its path" do
    t = transport(done.merge("selection" => true), "report-payload" => [report])

    expect(pipeline(t).run).to eq(out)
    expect(t.calls.last).to eq(["report-payload", { args: { run: "RUN" } }])
    expect(File.read(out)).to include("<h1>QUAACK report RUN</h1>")
  end

  it "writes the report right after this run's selection step stores selection" do
    t = transport(done.merge("selection" => false), "report-payload" => [report])

    expect(pipeline(t).run).to eq(out)
    expect(t.calls.map(&:first).last(2)).to eq(%w[selection report-payload])
  end

  it "puts the client's LLM call counts in the report's burndown" do
    burndown = Quaack::Driver::Burndown.new
    burndown.llm_call("5a-5")
    burndown.llm_call("5a-5")
    client = FakeLLM.new.client(burndown:)
    t = transport(done.merge("selection" => true), "report-payload" => [report])

    described_class.new(transport: t, client:, run_id: "RUN", out:).run

    expect(File.read(out)).to include("<li>Index suggestions for the original query: 2 calls</li>")
  end

  it "fails with no_report when the enclave sends no report" do
    t = transport(done.merge("selection" => true))

    expect { pipeline(t).run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("no_report") }
  end
end
