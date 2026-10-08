# frozen_string_literal: true

require_relative "spec_helper"

# Task 20261003-18: when rewrite-test can't build scenarios for the query, the run
# still finishes. A two-column CHECK on orders is a complex_check refusal
# (DESIGN.md's rewrite-test), so the key_in_self_join rule's rewrite, the run's only
# one, is never tested: it's marked untested, never recommended, and the
# report says why, by rule. The index steps still run, and a resumed run
# skips the refused rewrite rather than trying it again. The run happens
# once, and the examples below share it.
module ScenarioRefusalRun
  CHECK = "ALTER TABLE public.orders ADD CONSTRAINT orders_updated_after_created CHECK (updated_at >= created_at)"
  QUERY = PipelineReplay::RULE_QUERY.with(name: "scenario_refusal")

  Runs = Data.define(:run_id, :first_error, :second_error, :report, :html, :entries, :stderr)

  module_function

  def cached
    @cached ||= begin
      server = TestPostgres.server
      Dir.mktmpdir("quaack-refusal") do |home|
        prod, racetrack = PromptPack.databases(server, QUERY)
        [prod, racetrack].each { add_check(server, it) }
        PromptPack.with_env(home, server, prod) { twice(home, server, prod, racetrack) }
      ensure
        PipelineReplay.drop(server, [prod, racetrack, "#{racetrack}_arena"].compact)
      end
    end
  end

  def add_check(server, db)
    conn = PG.connect(host: server.host, port: server.port, dbname: db, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec(CHECK)
  ensure
    conn&.close
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

RSpec.describe ScenarioRefusalRun do
  def self.refusal_spec(&)
    TestPgDump.examples(self, "runs the pipeline, with a pg_dump of the test server's major version", &)
  end

  refusal_spec do
    let(:runs) { described_class.cached }
    let(:rewrite) { runs.report["rewrites"].find { it["rewrite"] == "rewrite_1" } }

    it "finishes both runs and writes the report" do
      expect([runs.first_error, runs.second_error]).to eq([nil, nil])
      expect(runs.report).to include("type" => "report")
      expect(runs.html).to include("<html")
    end

    it "records the refusal in the store, so the rewrite is never measured" do
      expect(runs.entries).to include("rewrite_1" => true, "rewrite_tested_1" => true,
                                      "rewrite_survived_1" => true, "rewrite_index_ideas_1" => false)
    end

    it "sends the rewrite as untested, by the refusal's rule, and never ranks it" do
      expect(rewrite).to include("fate" => "rewrite_test_untested", "rule" => "complex_check")
      labels = (runs.report["top"] + runs.report["labels"]).map { it["label"] }
      expect(labels.grep(/\Arewrite_1:/)).to be_empty
      expect(runs.report["rule_bugs"]).to eq([])
    end

    it "still runs the index steps for the original query" do
      expect(runs.entries).to include("index_build" => true, "candidate_runs" => true, "selection" => true)
      expect(runs.report["labels"].map { it["label"] }).to include(start_with("original:"))
    end

    it "says in the report file that the rewrite was never tested, and why" do
      expect(runs.html).to include("QUAACK couldn&#39;t make up test data for your query, because a CHECK " \
                                   "constraint on its tables is too complex for QUAACK to satisfy, so it never " \
                                   "tested this rewrite and won&#39;t recommend it.")
    end

    it "skips the refused rewrite on resume instead of testing it again, under its name" do
      name = Quaack::Driver::RewriteNames.name(runs.run_id, 1)
      expect(runs.stderr).to include("Rewrite #{name}: Already done, skipping: Testing the rewrite for wrong " \
                                     "results (rewrite-correctness)")
      expect(runs.stderr).not_to include("(rewrite-test)")
    end
  end
end
