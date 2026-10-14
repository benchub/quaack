# frozen_string_literal: true

require_relative "spec_helper"

# Task 20261012-4: a rewrite rewrite-test's search couldn't test isn't
# disproved, so it goes on to the LLM's counterexamples and measurement,
# and the report cautions why it wasn't tested, by a fixed reason word. The
# key_in_self_join rule's rewrite, the run's only one, runs with the search
# turned off (PipelineReplay.without_fuzz), whose reason is fuzz_off: the
# same path as a query the search can't take. A resumed run skips the
# rewrite rather than trying it again. The run happens once, and the
# examples below share it.
module NotTestedRun
  QUERY = PipelineReplay::RULE_QUERY.with(name: "not_tested")

  Runs = Data.define(:run_id, :first_error, :second_error, :report, :html, :entries, :stderr)

  module_function

  def cached
    @cached ||= PipelineReplay.without_fuzz do
      server = TestPostgres.server
      Dir.mktmpdir("quaack-not-tested") do |home|
        prod, racetrack = PromptPack.databases(server, QUERY)
        PromptPack.with_env(home, server, prod) { twice(home, server, prod, racetrack) }
      ensure
        PipelineReplay.drop(server, [prod, racetrack, "#{racetrack}_arena"].compact)
      end
    end
  end

  # The Pipeline runs once, then again over the same store, as `quaack run`
  # does when it resumes a run, and then the run is torn down.
  def twice(home, server, prod, racetrack)
    transport = Quaack::Driver::Transport::Local.new(command: PromptPack::QUAACKS)
    run_id = PromptPack.intake(transport, home, server, QUERY, prod)
    PromptPack.setup(transport, run_id, server, racetrack)
    out = File.join(home, "report.html")
    Quaack::Driver::Teardown.around(transport:, run_id:, stderr: StringIO.new, jump: "jump-1") do
      first, second = Array.new(2) { pipeline(transport, run_id, out) }
      read_back(transport, run_id, out, first, second)
    end
  end

  # nil or the error that ended the run, and what the run said on stderr.
  def pipeline(transport, run_id, out)
    client = Quaack::Driver::LLM::Router.one(E2ERun::CaseLLM.new.client(burndown: Quaack::Driver::Burndown.new))
    stderr = StringIO.new
    error = PipelineReplay.drive { Quaack::Driver::Pipeline.new(transport:, client:, run_id:, out:, stderr:).run }
    [error, stderr.string]
  end

  def read_back(transport, run_id, out, first, second)
    errors = [first.first, second.first]
    Runs.new(run_id:, first_error: errors.first, second_error: errors.last, stderr: second.last,
             report: (PipelineReplay.report(transport, run_id) if errors.none?),
             html: (File.read(out) if File.exist?(out)), entries: Quaack::Driver::Pipeline.status(transport, run_id))
  end
end

RSpec.describe NotTestedRun do
  TestPgDump.examples(self, "runs the pipeline, with a pg_dump of the test server's major version") do
    let(:runs) { described_class.cached }
    let(:rewrite) { runs.report["rewrites"].find { it["rewrite"] == "rewrite_1" } }

    it "finishes both runs and writes the report" do
      expect([runs.first_error, runs.second_error]).to eq([nil, nil])
      expect(runs.report).to include("type" => "report")
      expect(runs.html).to include("<html")
    end

    it "sends the rewrite on to counterexamples and measurement, with why it wasn't tested, and no rule bug" do
      expect(runs.entries).to include("rewrite_tested_1" => true, "rewrite_survived_1" => true,
                                      "rewrite_index_ideas_1" => true)
      expect(rewrite).to include("not_tested" => "fuzz_off", "out_of_time" => false)
      expect(rewrite["fate"]).not_to start_with("rewrite_test")
      expect(runs.report["rule_bugs"]).to eq([])
    end

    it "counts the rewrite in the burndown as gone on untested, and records no rewrite-test stage" do
      stages = runs.report["burndown"]["stages"]
      expect(stages.dig("fuzz", "rewrite_1")).to include("in" => 1, "out" => 1, "dropped" => {})
      expect(stages.dig("fuzz", "rewrite_1", "extra")).to include("trials" => 0, "untested" => 1)
      expect(stages.dig("counterexamples", "rewrite_1")).to include("in" => 1)
      expect(stages).not_to have_key("rewrite-test")
    end

    it "says in the report file that QUAACK didn't test the rewrite on made-up data, and why" do
      expect(runs.html).to include("QUAACK didn&#39;t test it on made-up data, since a test setting turned the " \
                                   "test off, so it checked it only on test data the LLM wrote to break it and on " \
                                   "the real data.")
    end

    it "skips the rewrite on resume instead of testing it again, under its name" do
      name = Quaack::Driver::RewriteNames.name(runs.run_id, 1)
      expect(runs.stderr).to include("Rewrite #{name}: Already done, skipping: Testing the rewrite for wrong " \
                                     "results (rewrite-correctness)")
      expect(runs.stderr).not_to include("(rewrite-test)")
    end
  end
end
