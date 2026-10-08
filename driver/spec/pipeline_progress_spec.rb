# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/pipeline"
require_relative "support/fake_llm"
require_relative "support/routers"

PROGRESS_SENTINEL = "sentinel-20261003-15-c0ffee"

# Each step's closing line in `quaack run`'s progress: what the step did,
# from its result, then its time.
RSpec.describe Quaack::Driver::Pipeline, "progress summaries" do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
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
      define_method(:call) do |subcommand, input: nil, args: {}, **, &progress|
        index = args[:index]
        s.fetch(subcommand, []).select { index.nil? || it["index"] == index.to_i }.each { progress&.call(it) }
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

  # A stored rewrite through plan-pruning.
  def rewrite(number, **more)
    { "rewrite_#{number}" => true, "index_search_rewrite_#{number}" => true,
      "index_ranking_rewrite_#{number}" => true, "rewrite_pruned_#{number}" => true,
      "rewrite_survived_#{number}" => true }.merge(more.transform_keys { "#{it}_#{number}" })
  end

  it "says how many index ideas the LLM gave in llm-index-ideas, and how many were new" do
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

  it "says when the LLM gave no index ideas in llm-index-ideas" do
    entries["index_generated_original"] = false
    fake.reply("llm-index-ideas", { "indexes" => [] })

    run

    expect(closing("llm-index-ideas")).to eq(["Got no index ideas from the LLM"])
  end

  it "says how many revised index ideas the LLM gave in llm-index-refine, and how many were new" do
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => false,
                                   "candidates" => [{ "shortfall" => "unused" }], "baseline" => {} }]
    fake.reply("llm-index-refine", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
    replies["index-test"] = outcomes("index_outcome", { "outcome" => "accepted" })

    run

    expect(closing("llm-index-refine")).to eq(["Got 1 revised index idea from the LLM, 1 of them new"])
  end

  it "says when llm-index-refine already improved the index ideas, on a resumed run" do
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => true }]

    run

    expect(closing("llm-index-refine")).to eq(["Already improved the index ideas"])
  end

  it "says how many rewrites QUAACK's rules made in rewrite-rules and how many were kept, or that none applied" do
    entries["rewrite_rules_applied"] = false
    replies["rewrite-rules"] = outcomes("rewrite_outcome", { "outcome" => "accepted", "rewrite" => "rewrite_1" },
                                        { "outcome" => "rejected", "rule" => "plan_unchanged" },
                                        { "outcome" => "accepted", "rewrite" => "rewrite_2" })
    run
    replies["rewrite-rules"] = []
    run

    expect(closing("rewrite-rules")).to eq(["QUAACK's rules made 3 rewrites, 2 kept", "No rule applied"])
  end

  it "says how many rewrites llm-rewrites gave, and how many of the operator's operator-rewrites checked and kept" do
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

  it "says when the operator gave no rewrites for operator-rewrites" do
    entries.merge!("rewrites_generated" => false, "operator_rewrites_checked" => false)
    fake.reply("llm-rewrites", { "rewrites" => [] })

    run(rewrites: [])

    expect(closing("operator-rewrites")).to eq(["You gave no rewrites to check"])
  end

  it "says when the LLM gave no rewrites in llm-rewrites" do
    entries["rewrites_generated"] = false
    fake.reply("llm-rewrites", { "rewrites" => [] })

    run

    expect(closing("llm-rewrites")).to eq(["Got no rewrites from the LLM"])
  end

  it "says how many rewrites plan-pruning, rewrite-correctness, and rewrite-index-ideas worked on, had, and passed" do
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

  it "counts a rewrite as asked in rewrite-index-ideas if llm-index-ideas, llm-index-refine, or index-rank had work" do
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

  it "says when plan-pruning and rewrite-index-ideas had already done every rewrite, on a resumed run" do
    entries.merge!(rewrite(1, rewrite_index_ideas: true, index_generated_rewrite: true, index_llm_ranked_rewrite: true),
                   rewrite(2))
    replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => true }]

    run

    expect([closing("plan-pruning"),
            closing("rewrite-index-ideas")]).to eq([["2 rewrites already done"], ["1 rewrite already done"]])
  end

  it "says a rewrite counterexamples disproved didn't pass" do
    entries.merge!(rewrite(1, rewrite_survived: false))
    tests.push(true)
    fake.reply("llm-counterexamples", { "inserts" => [] })
    replies["counterexample-round"] = [{ "type" => "counterexample_round", "match" => false, "rule" => nil,
                                         "covered" => [], "refused" => [] }]

    run

    expect(closing("rewrite-correctness")).to eq(["Tested 1 rewrite, 0 passed"])
  end

  it "says when there are no rewrites for plan-pruning, rewrite-correctness, and rewrite-index-ideas" do
    run

    expect([closing("plan-pruning"), closing("rewrite-correctness"), closing("rewrite-index-ideas")])
      .to eq([["No rewrites to search"], ["No rewrites left to test"], ["No rewrites needed index ideas"]])
  end

  it "says how many indexes index-build built, what the measuring steps did, and where the report went" do
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

  it "says when index-build had no index to build" do
    entries["index_build"] = false

    run

    expect(closing("index-build")).to eq(["No index to build"])
  end

  # Each enclave call an LLM step makes gets a note of its own, so the
  # clock under an LLM ask's note never covers an enclave call.
  describe "notes for enclave calls under an LLM step" do
    let(:name) { Quaack::Driver::RewriteNames.label("RUN", "rewrite_1") }

    # The step's lines, from its opening line up to its closing line,
    # without "quaack: [n/t] ".
    def lines_of(step)
      lines = stderr.string.lines.map { it.chomp.sub(%r{\Aquaack: \[\d+/\d+\] }, "") }
      first = lines.index { it.end_with?("(#{step})") }
      last = lines.index { it.match?(/ in \d+s \(#{Regexp.escape(step)}\)\z/) }
      lines[first...last]
    end

    it "notes counterexample-payload and each counterexample-round under counterexamples" do
      entries.merge!(rewrite(1, rewrite_survived: false))
      tests.push(true)
      3.times { fake.reply("llm-counterexamples", { "inserts" => [] }) }

      run

      round = "#{name}: Loading the LLM's rows and comparing results (counterexamples)"
      again = "Asking the LLM again, for different rows (llm-counterexamples)"
      expect(lines_of("rewrite-correctness"))
        .to eq(["Testing each rewrite for wrong results (rewrite-correctness)",
                "#{name}: Testing the rewrite on generated rows (rewrite-test)",
                "#{name}: Asking the LLM for rows that could break the rewrite (counterexamples)",
                "#{name}: Reading the rewrite's shape for the LLM (counterexamples)",
                "Asking the LLM for rows that could break the rewrite (llm-counterexamples)",
                round, again, round, again, round])
    end

    it "notes index-payload and index-test under llm-index-ideas, and index-feedback and index-test under " \
       "llm-index-refine" do
      entries["index_generated_original"] = false
      fake.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
      fake.reply("llm-index-refine", { "indexes" => ["CREATE INDEX ON public.t (b)"] })
      replies["index-test"] = outcomes("index_outcome", { "outcome" => "accepted" })
      replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => false,
                                     "candidates" => [{ "shortfall" => "unused" }], "baseline" => {} }]

      run

      expect(lines_of("llm-index-ideas"))
        .to eq(["Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)",
                "Reading the query's shape for the LLM (llm-index-ideas)",
                "Asking the LLM for index ideas (llm-index-ideas)",
                "Testing the LLM's index ideas (llm-index-ideas)"])
      expect(lines_of("llm-index-refine"))
        .to eq(["Asking the LLM to improve its index ideas (llm-index-refine)",
                "Reading how the LLM's index ideas did (llm-index-refine)",
                "Asking the LLM (llm-index-refine)",
                "Testing the LLM's revised index ideas (llm-index-refine)"])
    end

    it "notes index-payload under llm-index-refine when llm-index-ideas was already done" do
      replies["index-feedback"] = [{ "type" => "index_feedback", "revise" => true, "refined" => false,
                                     "candidates" => [{ "shortfall" => "unused" }], "baseline" => {} }]
      fake.reply("llm-index-refine", { "indexes" => [] })

      run

      expect(lines_of("llm-index-refine"))
        .to eq(["Asking the LLM to improve its index ideas (llm-index-refine)",
                "Reading how the LLM's index ideas did (llm-index-refine)",
                "Reading the query's shape for the LLM (llm-index-refine)",
                "Asking the LLM (llm-index-refine)",
                "Testing the LLM's revised index ideas (llm-index-refine)"])
    end

    it "notes the index-test that records an llm-index-ideas with no ideas" do
      entries["index_generated_original"] = false
      fake.reply("llm-index-ideas", { "indexes" => [] })

      run

      expect(lines_of("llm-index-ideas"))
        .to eq(["Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)",
                "Reading the query's shape for the LLM (llm-index-ideas)",
                "Asking the LLM for index ideas (llm-index-ideas)",
                "Recording that the LLM gave no index ideas (llm-index-ideas)"])
    end

    it "notes rewrite-check under llm-rewrites and operator-rewrites" do
      entries.merge!("rewrites_generated" => false, "operator_rewrites_checked" => false)
      fake.reply("llm-rewrites",
                 { "rewrites" => [{ "sql" => "SELECT 1", "transformation" => "t", "assumptions" => [] }] })
      fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

      run(rewrites: ["SELECT 4"])

      expect(lines_of("llm-rewrites"))
        .to eq(["Asking the LLM for rewrites of the query (llm-rewrites)", "Asking the LLM (llm-rewrites)",
                "Checking the LLM's rewrites (llm-rewrites)"])
      expect(lines_of("operator-rewrites"))
        .to eq(["Checking your own rewrites (operator-rewrites)", "Asking the LLM (operator-rewrites)",
                "Checking your rewrites against what the LLM says they assume (operator-rewrites)"])
    end

    it "notes each rewrite's enclave calls under its rewrite-llm-index-ideas and rewrite-llm-index-refine" do
      entries.merge!(rewrite(1, rewrite_index_ideas: true, index_llm_ranked_rewrite: true))
      fake.reply("rewrite-llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.t (a)"] })
      replies["index-test"] = outcomes("index_outcome", { "outcome" => "accepted" })

      run

      expect(lines_of("rewrite-index-ideas"))
        .to eq(["Asking the LLM for index ideas for each rewrite (rewrite-index-ideas)",
                "#{name}: Asking the LLM for index ideas the mechanical search missed (rewrite-llm-index-ideas)",
                "#{name}: Reading the rewrite's shape for the LLM (rewrite-llm-index-ideas)",
                "Asking the LLM for index ideas (rewrite-llm-index-ideas)",
                "#{name}: Testing the LLM's index ideas (rewrite-llm-index-ideas)",
                "#{name}: Asking the LLM to improve its index ideas (rewrite-llm-index-refine)",
                "#{name}: Reading how the LLM's index ideas did (rewrite-llm-index-refine)",
                "#{name}: Already done, skipping: Ranking the index ideas (rewrite-index-rerank)"])
    end
  end

  # On a terminal, each line's clock gives its step's time, so a closing
  # line that only repeats the step is left out.
  describe "on a terminal" do
    let(:stderr) { Class.new(StringIO) { def tty? = true }.new }

    # Each line as it ends, without its redraws, number, or clock.
    def ended
      stderr.string.split("\n").map do |line|
        line.split("\r\e[K").last.sub(%r{\Aquaack: \[\d+/\d+\] }, "").sub(/ (?:\d+h)?(?:\d+m)?\d+s\z/, "")
      end
    end

    it "closes only the steps whose summaries carry more than the step's own line" do
      entries.merge!(%w[index_search_original index_generated_original index_ranking_original rewrite_rules_applied
                        rewrites_generated operator_rewrites_checked arena_setup index_build baseline index_baseline
                        candidate_runs minimax result_comparison selection].to_h { [it, false] })
      fake.reply("llm-index-ideas", { "indexes" => [] })
      fake.reply("llm-rewrites", { "rewrites" => [] })
      fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

      run(out:, rewrites: ["SELECT 9"])

      expect(ended.grep(/ in \d+s \(/).map { it[/\(([^()]+)\)\z/, 1] })
        .to eq(%w[index-search llm-index-ideas llm-index-refine index-rank rewrite-rules llm-rewrites
                  operator-rewrites plan-pruning arena-setup rewrite-correctness rewrite-index-ideas index-build
                  baseline index-baseline candidate-runs minimax result-comparison selection report])
      # Task 20261004-1: each enclave step now says how much it did, so
      # every step with a summary closes.
    end

    it "waits on a short line for counterexamples' first ask, which repeats its sub-step, and keeps the asks again" do
      entries.merge!(rewrite(1, rewrite_survived: false))
      tests.push(true)
      3.times { fake.reply("llm-counterexamples", { "inserts" => [] }) }
      name = Quaack::Driver::RewriteNames.label("RUN", "rewrite_1")

      run

      expect(ended.select { it.include?("(counterexamples)") || it.include?("(llm-counterexamples)") })
        .to eq(["#{name}: Asking the LLM for rows that could break the rewrite (counterexamples)",
                "#{name}: Reading the rewrite's shape for the LLM (counterexamples)",
                "Waiting for the LLM (llm-counterexamples)",
                "#{name}: Loading the LLM's rows and comparing results (counterexamples)",
                "Asking the LLM again, for different rows (llm-counterexamples)",
                "#{name}: Loading the LLM's rows and comparing results (counterexamples)",
                "Asking the LLM again, for different rows (llm-counterexamples)",
                "#{name}: Loading the LLM's rows and comparing results (counterexamples)"])
    end

    it "waits on a short line for llm-index-ideas' ask, which repeats its step, after the query's shape note" do
      entries["index_generated_original"] = false
      fake.reply("llm-index-ideas", { "indexes" => [] })

      run

      first = ended.index("Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)")
      expect(ended[first, 4])
        .to eq(["Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)",
                "Reading the query's shape for the LLM (llm-index-ideas)",
                "Waiting for the LLM (llm-index-ideas)",
                "Recording that the LLM gave no index ideas (llm-index-ideas)"])
    end
  end

  # Task 20261004-1: the steps that say how much they did from the
  # enclave's step_counts, and fall back to saying only what they did
  # without one.
  describe "step counts from the enclave" do
    def counts(**fields) = [{ "type" => "step_counts", **fields.transform_keys(&:to_s) }]

    it "says how many indexes index-search found and the planner used, and what index-rank ranked" do
      entries.merge!("index_search_original" => false, "index_ranking_original" => false)
      replies["index-search"] = counts(found: 12, used: 3)
      replies["index-rank"] = counts(ranked: 3, combined: 2)

      run

      expect(closing("index-search")).to eq(["Found 12 possible indexes mechanically, 3 used by the planner"])
      expect(closing("index-rank")).to eq(["Ranked the top 3 indexes, and a combination of 2"])
    end

    it "says when index-search found nothing and index-rank had nothing to rank" do
      entries.merge!("index_search_original" => false, "index_ranking_original" => false)
      replies["index-search"] = counts(found: 0, used: 0)
      replies["index-rank"] = counts(ranked: 0, combined: 0)

      run

      expect([closing("index-search"), closing("index-rank")])
        .to eq([["Found no possible index mechanically"], ["No index to rank"]])
    end

    it "names the rules that fired in rewrite-rules, with an Oxford comma" do
      entries["rewrite_rules_applied"] = false
      accepted = outcomes("rewrite_outcome", { "outcome" => "accepted", "rewrite" => "rewrite_1" },
                          { "outcome" => "rejected", "rule" => "plan_unchanged" })
      replies["rewrite-rules"] = accepted + counts(rules: %w[key_in_self_join])
      run
      replies["rewrite-rules"] = accepted + counts(rules: %w[shared_scan_cte key_in_self_join or_to_union])
      run

      expect(closing("rewrite-rules"))
        .to eq(["QUAACK's rules made 2 rewrites, 1 kept, with key_in_self_join",
                "QUAACK's rules made 2 rewrites, 1 kept, with shared_scan_cte, key_in_self_join, and or_to_union"])
    end

    it "says how much each measuring step did" do
      entries.merge!(%w[arena_setup baseline index_baseline candidate_runs minimax result_comparison
                        selection].to_h { [it, false] })
      replies.merge!("arena-setup" => counts(tables: 12), "baseline" => counts(sets: 3, timed_out: 1),
                     "index-baseline" => counts(combinations: 4, timed_out: 0),
                     "candidate-runs" => counts(measured: 5, timed_out: 2),
                     "minimax" => counts(compared: 6, survivors: 2),
                     "result-comparison" => counts(compared: 3, discarded: 1, partial: 2),
                     "selection" => counts(top: 2, excluded: 4))

      run

      steps = %w[arena-setup baseline index-baseline candidate-runs minimax result-comparison selection]
      expect(steps.map { closing(it) })
        .to eq([["Set up the arena with 12 tables"], ["Measured the original query on 3 literal sets, 1 timed out"],
                ["Measured the original query with 4 sets of indexes"], ["Measured 5 rewrite runs, 2 timed out"],
                ["Checked 6 choices against the original on every literal, 2 held up"],
                ["Checked the rows of 3 rewrites on production data, 1 differed, 2 checks partial"],
                ["Picked 2 top choices, 4 left out"]])
    end

    it "counts candidate-runs' timed-out runs as measured, even when every run timed out" do
      entries["candidate_runs"] = false
      replies["candidate-runs"] = counts(measured: 3, timed_out: 3)

      run

      expect(closing("candidate-runs")).to eq(["Measured 3 rewrite runs, 3 timed out"])
    end

    it "says when the measuring steps had nothing to measure or pick" do
      entries.merge!(%w[candidate_runs minimax result_comparison selection].to_h { [it, false] })
      replies.merge!("candidate-runs" => counts(measured: 0, timed_out: 0),
                     "minimax" => counts(compared: 0, survivors: 0),
                     "result-comparison" => counts(compared: 0, discarded: 0, partial: 0),
                     "selection" => counts(top: 0, excluded: 0))

      run

      expect(%w[candidate-runs minimax result-comparison selection].map { closing(it) })
        .to eq([["No rewrites to measure"], ["No choices to check against the original"],
                ["No rewrites to check on production data"], ["No choice beat the original"]])
    end

    it "leaves out a combination, partial checks, and choices left out when there are none" do
      entries.merge!(%w[index_ranking_original result_comparison selection].to_h { [it, false] })
      replies.merge!("index-rank" => counts(ranked: 2, combined: 0),
                     "result-comparison" => counts(compared: 1, discarded: 0, partial: 0),
                     "selection" => counts(top: 1, excluded: 0))

      run

      expect(%w[index-rank result-comparison selection].map { closing(it) })
        .to eq([["Ranked the top 2 indexes"], ["Checked the rows of 1 rewrite on production data, 0 differed"],
                ["Picked 1 top choice"]])
    end

    it "says only what a step did when its step_counts lacks a count the summary needs" do
      entries.merge!("index_search_original" => false, "baseline" => false)
      replies.merge!("index-search" => counts(found: 3), "baseline" => counts(timed_out: 0))

      run

      expect([closing("index-search"), closing("baseline")])
        .to eq([["Searched for indexes"], ["Measured the original query"]])
    end

    it "refuses a forged step_counts, with a string where a count belongs or a name not on the list" do
      entries.merge!("index_search_original" => false, "rewrite_rules_applied" => false, "arena_setup" => false)
      replies["index-search"] = counts(found: PROGRESS_SENTINEL, used: 1)
      replies["arena-setup"] = counts(tables: "12")
      replies["rewrite-rules"] = outcomes("rewrite_outcome", { "outcome" => "accepted", "rewrite" => "rewrite_1" }) +
                                 counts(rules: ["key_in_self_join", PROGRESS_SENTINEL])

      run

      expect([closing("index-search"), closing("arena-setup"), closing("rewrite-rules")])
        .to eq([["Searched for indexes"], ["Set up the arena"], ["QUAACK's rules made 1 rewrite, 1 kept"]])
      expect(stderr.string).not_to include(PROGRESS_SENTINEL)
    end
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

# index-build's first call's progress line gives the total. The transport
# rescues an error in the progress block, such as a closed stderr under the
# printer, so the total must be taken before the line is printed, or a
# failed print would leave it 0 and skip the rest of the indexes.
RSpec.describe Quaack::Driver::Pipeline::MeasurementStage, "when printing index-build's progress fails" do
  # Stands in for the ssh transport, at the edge: index 1's call hands its
  # block a progress line that counts three indexes, and, like the real
  # transport, rescues what the block raises.
  let(:transport) do
    calls = []
    Object.new.tap do |transport|
      transport.define_singleton_method(:calls) { calls }
      transport.define_singleton_method(:call) do |subcommand, args: {}, **, &progress|
        calls << [subcommand, args[:index]]
        begin
          progress&.call({ "type" => "index_build_progress", "index" => 1, "total" => 3 }) if args[:index] == "1"
        rescue StandardError
          nil
        end
        Data.define(:messages).new(messages: [])
      end
    end
  end

  it "still builds every index the first progress line counts" do
    progress = Object.new.tap { it.define_singleton_method(:note) { |_| raise Errno::EPIPE } }

    total = described_class.build_indexes(transport, "RUN", progress)

    expect([total, transport.calls]).to eq([3, [%w[index-build 1], %w[index-build 2], %w[index-build 3],
                                                ["index-build", nil]]])
  end
end
