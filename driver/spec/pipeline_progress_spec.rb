# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/pipeline"
require_relative "support/fake_llm"

PROGRESS_SENTINEL = "sentinel-20261003-15-c0ffee"

# Each step's closing line in `quaack run`'s progress: what the step did,
# from its result, then its time.
RSpec.describe Quaack::Driver::Pipeline, "progress summaries" do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:stderr) { StringIO.new }
  let(:dir) { Dir.mktmpdir("quaack-progress") }
  let(:out) { File.join(dir, "report.html") }
  # Every step's output stored; each spec marks the ones it runs as not.
  let(:entries) do
    %w[index_search_original index_generated_original index_ranking_original rewrite_rules_applied
       rewrites_generated arena_setup index_build baseline index_baseline candidate_runs minimax result_comparison
       selection].to_h { [it, true] }
  end
  let(:report) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => [], "indexes" => {}, "original_plan" => [],
      "timed_out_count" => 0 }
  end
  let(:replies) do
    { "index-payload" => [{ "type" => "index_payload", "query" => "SELECT 1" }],
      "index-feedback" => [{ "type" => "index_feedback", "revise" => false, "refined" => false }],
      "rewrite-payload" => [{ "type" => "rewrite_payload", "query" => "SELECT 1" }],
      "counterexample-payload" => [{ "type" => "counterexample_payload", "original" => "SELECT 1" }],
      "counterexample-round" => [{ "type" => "counterexample_round", "match" => true, "rule" => nil,
                                   "covered" => [], "refused" => [] }],
      "report-payload" => [report] }
  end
  # Progress messages a call hands its block, by subcommand.
  let(:streamed) { {} }
  # rewrite-test's passed, for each call in turn.
  let(:tests) { [] }

  # Stands in for the ssh transport, at the edge. A reply may be a lambda
  # of the call's input.
  let(:transport) do
    r = replies
    s = streamed
    e = entries
    t = tests
    Class.new do
      define_method(:call) do |subcommand, input: nil, **, &progress|
        s.fetch(subcommand, []).each { progress&.call(it) }
        messages = case subcommand
                   when "status" then [{ "type" => "status", "entries" => e }]
                   when "rewrite-test"
                     [{ "type" => "rewrite_test", "passed" => t.shift, "rule" => PROGRESS_SENTINEL }]
                   else r.fetch(subcommand, []).then { it.respond_to?(:call) ? it.call(input) : it }
                   end
        Data.define(:messages).new(messages:)
      end
    end.new
  end

  after { FileUtils.rm_rf(dir) }

  def run(rewrites: nil, out: nil)
    described_class.new(transport:, client:, run_id: "RUN", stderr:, rewrites:, out:).run
  end

  # The step's closing line, without its number or time.
  def closing(name)
    stderr.string.lines.grep(/ in \d+s \(#{Regexp.escape(name)}\)\n\z/).map do |line|
      line.sub(%r{\Aquaack: \[\d+/\d+\] }, "").sub(/ in \d+s \(.*\n\z/, "")
    end
  end

  def outcomes(type, *kinds) = kinds.each_with_index.map { |kind, i| { "type" => type, "index" => i + 1, **kind } }

  # A stored rewrite through step 8.
  def rewrite(number, **more)
    { "rewrite_#{number}" => true, "index_search_rewrite_#{number}" => true,
      "index_ranking_rewrite_#{number}" => true, "rewrite_pruned_#{number}" => true,
      "rewrite_survived_#{number}" => true }.merge(more.transform_keys { "#{it}_#{number}" })
  end

  it "says how many index ideas the LLM gave in 5a-5, and how many were new" do
    entries.merge!("index_search_original" => false, "index_generated_original" => false,
                   "index_ranking_original" => false)
    fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.t (a)", "CREATE INDEX ON public.t (b)",
                                                  "CREATE INDEX ON public.t USING gin (c)"] })
    fake.reply("llm-index-ideas", { "indexes" => [] })
    replies["index-test"] = outcomes("index_outcome", { "outcome" => "accepted" },
                                     { "outcome" => "dropped", "rule" => "duplicate" },
                                     { "outcome" => "set_aside" })

    run

    expect(closing("index-search")).to eq(["Searched for indexes"])
    expect(closing("llm-index-ideas"))
      .to eq(["Got 3 index ideas from the LLM, 1 of them new and tested, 1 set aside untested"])
    expect(closing("llm-index-refine")).to eq(["No index ideas needed improving"])
    expect(closing("index-rank")).to eq(["Ranked the index ideas"])
  end

  it "says when the LLM gave no index ideas in 5a-5" do
    entries["index_generated_original"] = false
    fake.reply("llm-index-ideas", { "indexes" => [] })

    run

    expect(closing("llm-index-ideas")).to eq(["Got no index ideas from the LLM"])
  end

  it "says how many revised index ideas the LLM gave in 5a-6, and how many were new" do
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => false,
                                   "candidates" => [{ "shortfall" => "unused" }], "baseline" => {} }]
    fake.reply("llm-index-refine", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
    replies["index-test"] = outcomes("index_outcome", { "outcome" => "accepted" })

    run

    expect(closing("llm-index-refine")).to eq(["Got 1 revised index idea from the LLM, 1 of them new"])
  end

  it "says when 5a-6 already improved the index ideas, on a resumed run" do
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => true }]

    run

    expect(closing("llm-index-refine")).to eq(["Already improved the index ideas"])
  end

  it "says how many rewrites QUAACK's rules made in 6c and how many were kept, or that none applied" do
    entries["rewrite_rules_applied"] = false
    replies["rewrite-rules"] = outcomes("rewrite_outcome", { "outcome" => "accepted", "rewrite" => "rewrite_1" },
                                        { "outcome" => "rejected", "rule" => "plan_unchanged" },
                                        { "outcome" => "accepted", "rewrite" => "rewrite_2" })
    run
    replies["rewrite-rules"] = []
    run

    expect(closing("rewrite-rules")).to eq(["QUAACK's rules made 3 rewrites, 2 kept", "No rule applied"])
  end

  it "says how many rewrites the LLM gave in 6a, and how many of the operator's step 7 checked, with how many kept" do
    entries.merge!("rewrites_generated" => false, "operator_rewrites_checked" => false)
    sql = ->(n) { { "sql" => "SELECT #{n}", "transformation" => "t", "assumptions" => [] } }
    fake.reply("llm-rewrites", { "rewrites" => [sql.call(1), sql.call(2), sql.call(3)] })
    fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] * 2 })
    replies["rewrite-check"] = lambda do |input|
      outcomes("rewrite_outcome", { "outcome" => "accepted", "rewrite" => "rewrite_1" },
               *([{ "outcome" => "rejected", "rule" => "plan_unchanged" }] * (input["rewrites"].size - 1)))
    end

    run(rewrites: ["SELECT 4", "SELECT 5"])

    expect(closing("llm-rewrites")).to eq(["Got 3 rewrites from the LLM, 1 kept"])
    expect(closing("operator-rewrites")).to eq(["Checked your 2 rewrites, 1 kept"])
  end

  it "says when the operator gave no rewrites for step 7" do
    entries.merge!("rewrites_generated" => false, "operator_rewrites_checked" => false)
    fake.reply("llm-rewrites", { "rewrites" => [] })

    run(rewrites: [])

    expect(closing("operator-rewrites")).to eq(["You gave no rewrites to check"])
  end

  it "says when the LLM gave no rewrites in 6a" do
    entries["rewrites_generated"] = false
    fake.reply("llm-rewrites", { "rewrites" => [] })

    run

    expect(closing("llm-rewrites")).to eq(["Got no rewrites from the LLM"])
  end

  it "says how many rewrites steps 8, 9-10, and 11 worked on, how many were already done, and how many passed" do
    entries.merge!(rewrite(1, index_search_rewrite: false, rewrite_survived: false, rewrite_index_ideas: true),
                   rewrite(2, rewrite_survived: false, rewrite_index_ideas: false),
                   rewrite(3, rewrite_index_ideas: true, index_generated_rewrite: true, index_llm_ranked_rewrite: true))
    tests.push(false, true)
    3.times { fake.reply("llm-counterexamples", { "inserts" => [] }) }
    fake.reply("rewrite-llm-index-ideas", { "indexes" => [] })

    run

    expect(closing("plan-pruning")).to eq(["Searched for indexes for 1 rewrite, 2 already done"])
    expect(closing("rewrite-correctness")).to eq(["Tested 2 rewrites, 1 passed"])
    expect(closing("rewrite-index-ideas")).to eq(["Asked for index ideas for 1 rewrite, 1 already done"])
  end

  it "counts a rewrite as asked in step 11 when any one of 5a-5, 5a-6, and 5a-7 still had work" do
    entries.merge!(rewrite(1, rewrite_index_ideas: true, index_llm_ranked_rewrite: true),
                   rewrite(2, rewrite_index_ideas: true, index_generated_rewrite: true),
                   rewrite(3, rewrite_index_ideas: true, index_generated_rewrite: true, index_llm_ranked_rewrite: true))
    feedback = [false, false, false, true].map do |revise|
      [{ "type" => "index_feedback", "revise" => revise, "refined" => false,
         "candidates" => [{ "shortfall" => "unused" }], "baseline" => {} }]
    end
    replies["index-feedback"] = ->(_) { feedback.shift }
    fake.reply("rewrite-llm-index-ideas", { "indexes" => [] })
    fake.reply("rewrite-llm-index-refine", { "indexes" => [] })

    run

    expect(closing("rewrite-index-ideas")).to eq(["Asked for index ideas for 3 rewrites"])
  end

  it "says when steps 8 and 11 had already done every rewrite, on a resumed run" do
    entries.merge!(rewrite(1, rewrite_index_ideas: true, index_generated_rewrite: true, index_llm_ranked_rewrite: true),
                   rewrite(2))
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => true }]

    run

    expect([closing("plan-pruning"),
            closing("rewrite-index-ideas")]).to eq([["2 rewrites already done"], ["1 rewrite already done"]])
  end

  it "says a rewrite steps llm-counterexamples-10c disproved didn't pass" do
    entries.merge!(rewrite(1, rewrite_survived: false))
    tests.push(true)
    fake.reply("llm-counterexamples", { "inserts" => [] })
    replies["counterexample-round"] = [{ "type" => "counterexample_round", "match" => false, "rule" => nil,
                                         "covered" => [], "refused" => [] }]

    run

    expect(closing("rewrite-correctness")).to eq(["Tested 1 rewrite, 0 passed"])
  end

  it "says when there are no rewrites for steps 8, 9-10, and 11" do
    run

    expect([closing("plan-pruning"), closing("rewrite-correctness"), closing("rewrite-index-ideas")])
      .to eq([["No rewrites to search"], ["No rewrites left to test"], ["No rewrites needed index ideas"]])
  end

  it "says how many indexes 12a built, what the measuring steps did, and where the report went" do
    entries.merge!(%w[arena_setup index_build baseline index_baseline candidate_runs minimax result_comparison
                      selection].to_h { [it, false] })
    streamed["index-build"] = [{ "type" => "index_build_progress", "index" => 1, "total" => 2, "ddl" => nil },
                               { "type" => "index_build_progress", "index" => 2, "total" => 2, "ddl" => nil }]

    run(out:)

    steps = %w[arena-setup index-build baseline index-baseline candidate-runs minimax result-comparison selection
               report]
    expect(steps.map { closing(it) })
      .to eq([["Set up the arena"], ["Built 2 indexes"], ["Measured the original query"],
              ["Measured the original query with each set of indexes"], ["Measured each rewrite"],
              ["Checked each choice against the original on every literal"],
              ["Checked each rewrite's rows on production data"], ["Picked the top choices"],
              ["Wrote the report to #{out}"]])
  end

  it "says when 12a had no index to build" do
    entries["index_build"] = false

    run

    expect(closing("index-build")).to eq(["No index to build"])
  end

  describe "trust boundary" do
    let(:planted) do
      { "rule" => PROGRESS_SENTINEL, "covered_by" => PROGRESS_SENTINEL, "rewrite" => PROGRESS_SENTINEL,
        "scenario" => PROGRESS_SENTINEL }
    end

    # Every step that has a summary runs, and every text field of every
    # reply a summary reads holds the sentinel.
    def plant
      entries.merge!(%w[index_search_original index_generated_original index_ranking_original rewrite_rules_applied
                        rewrites_generated operator_rewrites_checked index_build].to_h { [it, false] },
                     rewrite(1, index_search_rewrite: false, rewrite_survived: false, rewrite_index_ideas: true))
      %w[index-test rewrite-rules rewrite-check].each do |subcommand|
        replies[subcommand] = outcomes(subcommand == "index-test" ? "index_outcome" : "rewrite_outcome",
                                       { "outcome" => "accepted", **planted })
      end
      replies["counterexample-round"] = [{ "type" => "counterexample_round", "match" => true, **planted,
                                           "covered" => [PROGRESS_SENTINEL], "refused" => [] }]
      tests.push(true)
    end

    def llm_replies
      %w[llm-index-ideas rewrite-llm-index-ideas].each do |step|
        fake.reply(step, { "indexes" => ["CREATE INDEX ON public.t ((#{PROGRESS_SENTINEL.inspect}))"] })
      end
      fake.reply("llm-rewrites", { "rewrites" => [{ "sql" => "SELECT #{PROGRESS_SENTINEL.inspect}",
                                                    "transformation" => PROGRESS_SENTINEL, "assumptions" => [] }] })
      fake.reply("operator-rewrites",
                 { "rewrites" => [{ "transformation" => PROGRESS_SENTINEL, "assumptions" => [] }] })
      3.times { fake.reply("llm-counterexamples", { "inserts" => [] }) }
    end

    def leaks?(text) = text.include?(PROGRESS_SENTINEL)

    it "never puts what a step's result holds as text into the progress" do
      plant
      llm_replies
      streamed["index-build"] = [{ "type" => "index_build_progress", "index" => 1, "total" => 1, "ddl" => nil,
                                   "rule" => PROGRESS_SENTINEL }]

      run(rewrites: ["SELECT 9"])

      steps = %w[llm-index-ideas rewrite-rules llm-rewrites operator-rewrites plan-pruning rewrite-correctness
                 rewrite-index-ideas index-build]
      expect(steps.map { closing(it) })
        .to eq([["Got 1 index idea from the LLM, 1 of them new"], ["QUAACK's rules made 1 rewrite, 1 kept"],
                ["Got 1 rewrite from the LLM, 1 kept"], ["Checked your 1 rewrite, 1 kept"],
                ["Searched for indexes for 1 rewrite"], ["Tested 1 rewrite, 1 passed"],
                ["Asked for index ideas for 1 rewrite"], ["Built 1 index"]])
      expect(leaks?(stderr.string)).to be(false)
    end

    it "catches a sentinel that reaches the progress" do
      plant
      llm_replies
      streamed["index-build"] = [{ "type" => "index_build_progress", "index" => 1, "total" => 1,
                                   "ddl" => "CREATE INDEX quaack_1 ON public.t (#{PROGRESS_SENTINEL})" }]

      run(rewrites: ["SELECT 9"])

      expect(leaks?(stderr.string)).to be(true)
    end
  end
end
