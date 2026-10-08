# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/cli"
require "quaack/driver/enclave_error"
require "quaack/driver/runs"
require_relative "support/anthropic_credentials"
require_relative "support/aws_credentials"
require_relative "support/fake_llm"
require_relative "support/fake_openai"

RSpec.describe "quaack run" do
  let(:home) { Dir.mktmpdir("quaack-cli-run") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:fake) { FakeLLM.new }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:hosts) { [] }
  # Setup's outputs, all stored: the run has had setup.
  let(:setup_done) do
    %w[inventory run_server qualified_query schema_subset statistics volatility classification redacted_plan
       literal_sets clock_replacements racetrack_setup].to_h { [it, true] }
  end
  let(:entries) do
    setup_done.merge(
      "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
      "rewrite_rules_applied" => true, "rewrites_generated" => true, "arena_setup" => true, "index_build" => true,
      "baseline" => true,
      "index_baseline" => true, "candidate_runs" => true, "minimax" => true, "result_comparison" => true,
      "selection" => true
    )
  end
  let(:report) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => [], "indexes" => {}, "original_plan" => [],
      "timed_out_count" => 0 }
  end
  let(:out) { File.join(home, "r.html") }
  let(:replies) do
    { "version" => [{ "type" => "version", "version" => Quaack::Driver::ENCLAVE_VERSION }],
      "status" => [{ "type" => "status", "entries" => entries }],
      "index-payload" => [{ "type" => "index_payload" }],
      "index-feedback" => [{ "type" => "index_feedback", "revise" => false, "refined" => false }],
      "rewrite-payload" => [{ "type" => "rewrite_payload", "query" => "SELECT $1" }],
      "rewrite-check" => [{ "type" => "rewrite_outcome", "index" => 0, "outcome" => "accepted" }],
      "report-payload" => [report],
      "teardown" => [{ "type" => "teardown", "run_id" => run_id, "store" => "deleted",
                       "next_step" => "destroy_run_server" }] }
  end
  let(:torn) { "quaack: deleted the store for run #{run_id}. Destroy the run server for run #{run_id} now.\n" }

  # Stands in for ssh, at the edge: records each call.
  let(:failing) { {} }
  # Progress messages a call hands its block, by subcommand, as the real
  # transport does while the run goes on. A call with --index streams only
  # that index's messages, as `quaacks index-build --index` does.
  let(:streamed) { {} }
  let(:transport) do
    r = replies
    f = failing
    s = streamed
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options, &progress|
        @calls << [subcommand, options]
        index = options.dig(:args, :index)
        s.fetch(subcommand, []).select { index.nil? || it["index"] == index.to_i }.each { progress&.call(it) }
        raise f[subcommand] if f.key?(subcommand)

        Data.define(:messages).new(messages: r.fetch(subcommand, []))
      end
    end.new
  end

  let(:cli) do
    t = transport
    h = hosts
    Quaack::Driver::CLI.new(stdout:, stderr:, home:,
                            transport: lambda { |host, **|
                              h << host
                              t
                            },
                            client: ->(_settings) { fake.client(burndown: Quaack::Driver::Burndown.new) })
  end

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  it "runs the pipeline over ssh to the run's jump host, from arena-setup through the report" do
    entries.transform_values! { false }.merge!(setup_done)
    entries.merge!("index_search_original" => true, "index_generated_original" => true,
                   "index_ranking_original" => true, "rewrite_rules_applied" => true, "rewrites_generated" => true)
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq([0, torn])
    expect(hosts).to eq(["jump-1"])
    expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback arena-setup status index-build
                                                  index-build baseline index-baseline candidate-runs minimax
                                                  result-comparison selection report-payload teardown])
    expect(transport.calls[1].last[:args]).to eq(run: run_id)
  end

  it "sends the --rewrites file's rewrites through operator-rewrites inside the pipeline, before plan-pruning" do
    file = File.join(home, "rewrites.sql")
    File.write(file, "SELECT 2 WHERE $1;\n")
    fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

    status = cli.run(["run", "--run", run_id, "--rewrites", file, "--out", out])

    expect([status, errors]).to eq([0, torn])
    expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback rewrite-payload rewrite-check status
                                                  status status report-payload teardown])
    expect(transport.calls[4].last[:input]["rewrites"].map { it["sql"] }).to eq(["SELECT 2 WHERE $1"])
    expect(fake.asks.map(&:step)).to eq(["operator-rewrites"])
  end

  # stderr without its progress lines.
  def errors = stderr.string.lines.grep_v(%r{\Aquaack: \[\d+/\d+\] }).join

  # stderr's progress lines, with each time as Ns.
  def progress = stderr.string.lines.grep(%r{\Aquaack: \[\d+/\d+\] }).map { it.sub(/ in \d+s \(/, " in Ns (") }

  describe "progress on stderr" do
    it "says in plain English what each step does as it starts and ends, numbered, and each skip" do
      entries.transform_values! { false }.merge!(setup_done)
      entries.merge!("index_search_original" => true, "index_generated_original" => true,
                     "index_ranking_original" => true, "rewrites_generated" => true)
      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      steps = [["arena-setup", "Setting up the arena, a second database for test rows", "Set up the arena"],
               ["rewrite-correctness", "Testing each rewrite for wrong results", "No rewrites left to test"],
               ["rewrite-index-ideas", "Asking the LLM for index ideas for each rewrite",
                "No rewrites needed index ideas"],
               ["index-build", "Building the candidate indexes", "No index to build"],
               ["baseline", "Measuring the original query", "Measured the original query"],
               ["index-baseline", "Measuring the original query with each set of indexes",
                "Measured the original query with each set of indexes"],
               ["candidate-runs", "Measuring each rewrite", "Measured each rewrite"],
               ["minimax", "Dropping choices that lose to the original on any literal",
                "Checked each choice against the original on every literal"],
               ["result-comparison", "Checking that each rewrite returns the same rows on production data",
                "Checked each rewrite's rows on production data"],
               ["selection", "Picking the top three", "Picked the top choices"],
               ["report", "Writing the report", "Wrote the report to #{out}"]]
      expect(progress).to eq(
        ["quaack: [1/18] Already done, skipping: Checking the query plan and searching for indexes (index-search)\n",
         "quaack: [2/18] Already done, skipping: " \
         "Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)\n",
         "quaack: [3/18] Asking the LLM to improve its index ideas (llm-index-refine)\n",
         "quaack: [3/18] Reading how the LLM's index ideas did (llm-index-refine)\n",
         "quaack: [3/18] No index ideas needed improving in Ns (llm-index-refine)\n",
         "quaack: [4/18] Already done, skipping: Ranking the index ideas (index-rank)\n",
         "quaack: [5/18] Applying QUAACK's own rewrite rules to the query (rewrite-rules)\n",
         "quaack: [5/18] No rule applied in Ns (rewrite-rules)\n",
         "quaack: [6/18] Already done, skipping: Asking the LLM for rewrites of the query (llm-rewrites)\n",
         "quaack: [7/18] Searching for indexes for each rewrite (plan-pruning)\n",
         "quaack: [7/18] No rewrites to search in Ns (plan-pruning)\n",
         *steps.each_with_index.flat_map do |(name, description, did), i|
           ["quaack: [#{8 + i}/18] #{description} (#{name})\n", "quaack: [#{8 + i}/18] #{did} in Ns (#{name})\n"]
         end]
      )
      expect(stdout.string).to eq("#{out}\n#{run_id} done\n")
    end

    it "counts operator-rewrites, and prints each LLM ask and retry, when there's a rewrites file" do
      reply = { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] }
      fake.error("operator-rewrites", status: 529).reply("operator-rewrites", reply)
      entries["rewrites_generated"] = false
      replies["rewrite-check"] = []
      fake.reply("llm-rewrites", { "rewrites" => [] })

      expect(cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])).to eq(0)

      expect(progress).to include("quaack: [5/19] Already done, skipping: " \
                                  "Applying QUAACK's own rewrite rules to the query (rewrite-rules)\n",
                                  "quaack: [6/19] Asking the LLM for rewrites of the query (llm-rewrites)\n",
                                  "quaack: [6/19] Asking the LLM (llm-rewrites)\n",
                                  "quaack: [7/19] Checking your own rewrites (operator-rewrites)\n",
                                  "quaack: [7/19] Asking the LLM (operator-rewrites)\n",
                                  "quaack: [7/19] Asking the LLM, attempt 2 (operator-rewrites)\n",
                                  "quaack: [7/19] Checked your 1 rewrite, 0 kept in Ns (operator-rewrites)\n",
                                  "quaack: [19/19] Writing the report (report)\n")
    end

    it "skips operator-rewrites on a resumed run with a rewrites file, and rewrite-correctness for each rewrite" do
      entries["operator_rewrites_checked"] = true
      [1, 2].each do |n|
        entries.merge!("rewrite_#{n}" => true, "index_search_rewrite_#{n}" => true,
                       "index_ranking_rewrite_#{n}" => true, "rewrite_pruned_#{n}" => true,
                       "rewrite_survived_#{n}" => true, "rewrite_index_ideas_#{n}" => true,
                       "index_generated_rewrite_#{n}" => true, "index_llm_ranked_rewrite_#{n}" => true)
      end

      expect(cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])).to eq(0)

      skipped = "Already done, skipping:"
      tested = "#{skipped} Testing the rewrite for wrong results (rewrite-correctness)"
      # The skips from rewrite-rules through rewrite-correctness, less plan-pruning's sub-steps.
      lines = progress.grep(%r{\Aquaack: \[([5-9]|10)/19\] (?!Rewrite \w+ \w+: .*\(rewrite-(index|prune))})
      expect(lines).to eq(
        ["quaack: [5/19] #{skipped} Applying QUAACK's own rewrite rules to the query (rewrite-rules)\n",
         "quaack: [6/19] #{skipped} Asking the LLM for rewrites of the query (llm-rewrites)\n",
         "quaack: [7/19] #{skipped} Checking your own rewrites (operator-rewrites)\n",
         "quaack: [8/19] Searching for indexes for each rewrite (plan-pruning)\n",
         "quaack: [8/19] 2 rewrites already done in Ns (plan-pruning)\n",
         "quaack: [9/19] #{skipped} Setting up the arena, a second database for test rows (arena-setup)\n",
         "quaack: [10/19] Testing each rewrite for wrong results (rewrite-correctness)\n",
         "quaack: [10/19] Rewrite Dreamy Wren: #{tested}\n",
         "quaack: [10/19] Rewrite Tawny Crab: #{tested}\n",
         "quaack: [10/19] No rewrites left to test in Ns (rewrite-correctness)\n"]
      )
      expect(fake.asks).to eq([])
    end

    it "prints a step's sub-steps for each rewrite, under the step, by the rewrite's name" do
      entries.merge!("rewrite_1" => true, "index_search_rewrite_1" => true, "index_ranking_rewrite_1" => false,
                     "rewrite_pruned_1" => true, "rewrite_survived_1" => true, "rewrite_index_ideas_1" => true,
                     "index_generated_rewrite_1" => true, "index_llm_ranked_rewrite_1" => true)

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      skipped = "Rewrite Dreamy Wren: Already done, skipping:"
      expect(progress).to include(
        "quaack: [7/18] #{skipped} Checking the query plan and searching for indexes (rewrite-index-search)\n",
        "quaack: [7/18] Rewrite Dreamy Wren: Ranking the index ideas (rewrite-index-rank)\n",
        "quaack: [7/18] #{skipped} Dropping the rewrite if its plan can't win (rewrite-prune)\n",
        "quaack: [9/18] #{skipped} Testing the rewrite for wrong results (rewrite-correctness)\n",
        start_with("quaack: [10/18] #{skipped} ")
      )
      expect(progress.grep(/Rewrite \d/)).to eq([])
    end

    it "prints each index that index-build builds as the enclave reports it, with its redacted DDL" do
      entries["index_build"] = false
      ddl = "CREATE INDEX quaack_505c95b84989bfd37136 ON public.orders USING btree (id, status) WHERE note = ?"
      streamed["index-build"] = [{ "type" => "index_build_progress", "index" => 1, "total" => 2, "ddl" => ddl },
                                 { "type" => "index_build_progress", "index" => 2, "total" => 2, "ddl" => nil }]

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      lines = progress.select { it.start_with?("quaack: [11/18]") }
      expect(lines).to eq(["quaack: [11/18] Building the candidate indexes (index-build)\n",
                           "quaack: [11/18] Building index 1/2: #{ddl}\n",
                           "quaack: [11/18] Building index 2/2\n",
                           "quaack: [11/18] Built 2 indexes in Ns (index-build)\n"])
    end

    # 20261004-11: each index gets its own enclave call, and so its own
    # timeout, then a plain call hides them all and writes index_build.
    it "builds each index in its own index-build call, then makes one plain call" do
      entries["index_build"] = false
      streamed["index-build"] = (1..3).map { { "type" => "index_build_progress", "index" => it, "total" => 3 } }

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      expect(transport.calls.select { it.first == "index-build" }.map { it.last[:args] })
        .to eq([{ run: run_id, index: "1" }, { run: run_id, index: "2" }, { run: run_id, index: "3" },
                { run: run_id }])
      expect(progress.grep(/Building index|Built/))
        .to eq(["quaack: [11/18] Building index 1/3\n", "quaack: [11/18] Building index 2/3\n",
                "quaack: [11/18] Building index 3/3\n", "quaack: [11/18] Built 3 indexes in Ns (index-build)\n"])
    end

    it "makes just the one plain index-build call when there's no index to build" do
      entries["index_build"] = false

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      expect(transport.calls.select { it.first == "index-build" }.map { it.last[:args] })
        .to eq([{ run: run_id, index: "1" }, { run: run_id }])
      expect(progress.grep(/index-build\)\n\z/).last).to eq("quaack: [11/18] No index to build in Ns (index-build)\n")
    end

    it "prints a failed line for the step that fails, before the failure" do
      failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)

      expect(progress.last).to eq("quaack: [3/18] Failed after 0s (llm-index-refine)\n")
      expect(errors).to eq("#{torn}quaack run failed: arena_missing\n")
    end
  end

  describe "when stderr is a pipe whose reader has closed" do
    # A real pipe, as when the program reading stderr exits.
    let(:pipe) { IO.pipe.tap { it.first.close } }
    let(:stderr) { pipe.last }

    after { stderr.close }

    it "stops writing progress and runs to the end, tears down, and exits 0" do
      entries.transform_values! { false }.merge!(setup_done)
      entries.merge!("index_search_original" => true, "index_generated_original" => true,
                     "index_ranking_original" => true, "rewrite_rules_applied" => true, "rewrites_generated" => true)

      status = cli.run(["run", "--run", run_id, "--out", out])

      expect([status, stdout.string]).to eq([0, "#{out}\n#{run_id} done\n"])
      expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback arena-setup status index-build
                                                    index-build baseline index-baseline candidate-runs minimax
                                                    result-comparison selection report-payload teardown])
    end

    it "still exits 1 when a step fails" do
      failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect(transport.calls.map(&:first).last).to eq("teardown")
    end
  end

  describe "when stdout is a pipe whose reader has closed" do
    # A real pipe, as when the program reading stdout exits.
    let(:pipe) { IO.pipe.tap { it.first.close } }
    let(:stdout) { pipe.last }

    after { stdout.close }

    it "writes the report, tears down, and exits 0 without printing its path" do
      expect([cli.run(["run", "--run", run_id, "--out", out]), errors]).to eq([0, torn])
      expect(File.read(out)).to include("QUAACK report #{run_id}")
      expect(transport.calls.map(&:first).last).to eq("teardown")
    end

    it "still exits 1 when teardown fails after the report" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "teardown_failed")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect(File.read(out)).to include("QUAACK report #{run_id}")
      expect(errors).to include("quaack run failed: teardown_failed")
    end
  end

  # `quaack run … 2>&1 | head`: one real pipe, its reader closed, for both.
  describe "when stdout and stderr are one pipe whose reader has closed" do
    let(:pipe) { IO.pipe.tap { it.first.close } }
    let(:stdout) { pipe.last }
    let(:stderr) { pipe.last }

    after { pipe.last.close }

    it "runs to the end, writes the report, tears down, and exits 0" do
      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)
      expect(File.read(out)).to include("QUAACK report #{run_id}")
      expect(transport.calls.map(&:first).last).to eq("teardown")
    end

    it "exits 1 when a step fails, and still tears down" do
      failing["report-payload"] = Quaack::Driver::EnclaveError.new(subcommand: "report-payload", rule: "arena_missing")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect(transport.calls.map(&:first).last).to eq("teardown")
    end

    it "exits with the usage status for an unknown run" do
      expect(cli.run(["run", "--run", "20260926T010203Z-ffffffff", "--out", out])).to eq(64)
    end
  end

  def rewrites_file(text = "SELECT 2 WHERE $1;\n")
    File.join(home, "rewrites.sql").tap { File.write(it, text) }
  end

  it "prints the run ID and done on success" do
    expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string]).to eq([0, "#{out}\n#{run_id} done\n"])
  end

  context "when selection is stored" do
    it "writes the report to --out and prints its path before done" do
      expect([cli.run(["run", "--run", run_id, "--out", out]), errors]).to eq([0, torn])
      expect(stdout.string).to eq("#{out}\n#{run_id} done\n")
      expect(File.read(out)).to include("QUAACK report #{run_id}")
    end

    it "writes the report to ./quaack-<run>.html by default" do
      expect(Dir.chdir(home) { cli.run(["run", "--run", run_id]) }).to eq(0)
      expect(stdout.string).to end_with("./quaack-#{run_id}.html\n#{run_id} done\n")
      expect(File.exist?(File.join(home, "quaack-#{run_id}.html"))).to be(true)
    end

    it "takes --out alongside --rewrites, in either order" do
      fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

      expect(cli.run(["run", "--run", run_id, "--out", out, "--rewrites", rewrites_file])).to eq(0)
      expect(File.exist?(out)).to be(true)
    end
  end

  it "fails with exit 1 and only the rule when an enclave call fails" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string, errors]).to eq([1, "", "#{torn}quaack run failed: arena_missing\n"])
  end

  it "says to start a new run when an older version of QUAACK started this one" do
    failing["status"] = Quaack::Driver::EnclaveError.new(subcommand: "status", rule: "run_from_older_version")

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string, errors]).to eq(
      [1, "", "#{torn}quaack run failed: run_from_older_version: an older version of QUAACK started this run, " \
              "and this version can't resume it. Start a new run with quaack start.\n"]
    )
  end

  # Task 20261003-22: run-server flags given to a run that's had setup go
  # unused, so it says so, naming only the flags.
  it "warns that the run-server flags go unused when the run has had setup" do
    status = cli.run(["run", "--run", run_id, "--out", out, "--arena-db", "ar", "--host", "rs-1"])

    expect(status).to eq(0)
    expect(transport.calls.map(&:first)).not_to include("run-server")
    expect(errors).to eq(
      "quaack: Ignoring --host and --arena-db, since the run already checked its run server. " \
      "To use another run server, start a new run with `quaack start`\n#{torn}"
    )
  end

  it "doesn't warn about run-server flags when none are given to a run that's had setup" do
    expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)
    expect(errors).to eq(torn)
  end

  # Task 20261004-17: the note names the jump host and production server
  # from the laptop's record of the run, and what to do next once the run
  # is torn down.
  it "names production and the jump host when a setup step can't connect to production" do
    Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1")
    entries.merge!(setup_done.transform_values { false })
    failing["inventory"] = Quaack::Driver::EnclaveError.new(subcommand: "inventory",
                                                            rule: "production_connection_failed", exit_status: 70)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to match(
      [1, start_with("#{torn}quaack run failed: production_connection_failed: couldn't connect to production at " \
                     "prod-1. ") & include("Test it with `ssh jump-1 'psql -h prod-1 -c ") &
          end_with("Otherwise fix your libpq setup, then start a new run with `quaack start`\n")]
    )
  end

  # Task 20261004-37: quaack run reads the port from the same record.
  it "gives psql the port quaack start recorded when a setup step can't connect to production" do
    Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1", port: "6543")
    entries.merge!(setup_done.transform_values { false })
    failing["inventory"] = Quaack::Driver::EnclaveError.new(subcommand: "inventory",
                                                            rule: "production_connection_failed", exit_status: 70)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to match(
      [1, include("couldn't connect to production at prod-1, port 6543. ") &
          include("Test it with `ssh jump-1 'psql -h prod-1 -p 6543 -c ")]
    )
  end

  it "names the jump host when a step can't connect to the run server" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback",
                                                                 rule: "run_server_connection_failed", exit_status: 70)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to match(
      [1, start_with("#{torn}quaack run failed: run_server_connection_failed: couldn't connect to the run server. ") &
          include("Test it with `ssh jump-1 'psql -h <host> -p <port>")]
    )
  end

  # Task 20261004-26: ssh is down, so teardown isn't tried, and the store is
  # left to resume.
  it "says when ssh couldn't reach the jump server, skips teardown, and gives the command that resumes the run" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "ssh_failed",
                                                                 exit_status: 255)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect(transport.calls.map(&:first)).not_to include("teardown")
    expect([status, errors]).to eq(
      [1, "quaack: skipped the teardown of run #{run_id}, since ssh to the jump server failed. To tear it down " \
          "later, run this on the jump server: quaacks teardown --run #{run_id}\n" \
          "quaack run failed: ssh_failed: couldn't ssh to the jump server; check your ssh login or network, " \
          "then resume with `quaack run --run #{run_id}`\n"]
    )
  end

  it "says when ssh couldn't reach the jump server for the version check, not that quaacks is missing" do
    failing["version"] = Quaack::Driver::EnclaveError.new(subcommand: "version", rule: "ssh_failed", exit_status: 255)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq(
      [1, "quaack run failed: ssh_failed: couldn't ssh to the jump server; check your ssh login or network, " \
          "then resume with `quaack run --run #{run_id}`\n"]
    )
  end

  it "names the call that died, and how, when an enclave call is incomplete, and says to start a new run" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "incomplete",
                                                                 exit_status: 255)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq(
      [1, "#{torn}quaack run failed: incomplete: quaacks index-feedback ended with exit 255. The ssh " \
          "session failed or ended, or the remote process was killed: check your ssh login, the network, and " \
          "the jump server's kernel log (for the OOM killer) and sshd log. " \
          "To go on, start a new run with `quaack start`\n"]
    )
  end

  # Task 20261004-26: "resume" only when the run's store is still there.
  describe "what to do after an incomplete call" do
    before do
      failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "incomplete",
                                                                   exit_status: 1)
    end

    let(:failed) { "quaack run failed: incomplete: quaacks index-feedback ended with exit 1. To go on, " }

    it "says to resume the run when --keep kept it" do
      expect(cli.run(["run", "--run", run_id, "--out", out, "--keep"])).to eq(1)
      expect(errors).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                           "quaacks teardown --run #{run_id}\n#{failed}resume with `quaack run --run #{run_id}`\n")
    end

    it "says to resume the run when teardown failed" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "incomplete",
                                                             exit_status: 255)

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect(errors).to eq("quaack: couldn't tear down run #{run_id} (incomplete). To tear it down later, run this " \
                           "on the jump server: quaacks teardown --run #{run_id}\n" \
                           "#{failed}resume with `quaack run --run #{run_id}`\n")
    end
  end

  # Tasks 20261004-29 and 20261004-31: after a good run, only teardown is
  # left, so resuming (which redoes the run's last steps) isn't the advice.
  # The report was written, so its path prints as after a clean run, but
  # not done. The teardown hint prints once, in teardown's own line.
  describe "what to do when teardown fails after a good run" do
    let(:teardown_left) { "tear the run down as said above (the run itself finished)" }
    let(:later) { "To tear it down later, run this on the jump server: quaacks teardown --run #{run_id}\n" }

    it "prints the report's path and says to run teardown, not to resume, when ssh fails during teardown" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "ssh_failed",
                                                             exit_status: 255)

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
      expect(errors).to eq("quaack: couldn't tear down run #{run_id} (ssh_failed). #{later}" \
                           "quaack run failed: ssh_failed: couldn't ssh to the jump server; check your ssh login " \
                           "or network, then #{teardown_left}\n")
    end

    it "prints the report's path and says to run teardown, not to resume, when the teardown call is incomplete" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "incomplete",
                                                             exit_status: 1)

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
      expect(errors).to eq("quaack: couldn't tear down run #{run_id} (incomplete). #{later}" \
                           "quaack run failed: incomplete: quaacks teardown ended with exit 1. " \
                           "To go on, #{teardown_left}\n")
    end

    # Task 20261004-32: a rule with no note of its own still points to
    # teardown's line, so the failure doesn't read as the run's own.
    %w[bad_run bad_store_base teardown_failed].each do |rule|
      it "prints the report's path, the by-hand hint, and a pointer to it when teardown fails as #{rule}" do
        failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule:)

        expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
        expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
        expect(errors).to eq("quaack: couldn't tear down run #{run_id} (#{rule}). Check or remove " \
                             "~/.quaack/runs/#{run_id} on the jump server by hand.\n" \
                             "quaack run failed: #{rule}. To go on, #{teardown_left}\n")
      end
    end

    it "prints the report's path, the command, and a pointer to it when destroy_command fails" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "destroy_command_failed")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
      expect(errors).to eq("quaack: couldn't tear down run #{run_id} (destroy_command_failed). #{later}" \
                           "quaack run failed: destroy_command_failed. To go on, #{teardown_left}\n")
    end

    # Task 20261004-60: teardown couldn't read the run's server, so its
    # destroy_command never ran, and the run server may still be up.
    it "prints the report's path, says to destroy the run server and remove the store, and points to it" do
      failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "destroy_command_not_run")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
      expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
      expect(errors).to eq("quaack: couldn't tear down run #{run_id} (destroy_command_not_run). destroy_command " \
                           "didn't run, so destroy the run server for run #{run_id} yourself. Then check or " \
                           "remove ~/.quaack/runs/#{run_id} on the jump server by hand.\n" \
                           "quaack run failed: destroy_command_not_run. To go on, #{teardown_left}\n")
    end

    # Task 20261004-60: an error from the driver itself, not the enclave,
    # gets the same path and pointer, and names only its rule, never the
    # error's message.
    [[IOError, "sentinel-io-7f3a"], [LoadError, "sentinel-load-9b2d"]].each do |klass, message|
      it "prints the report's path and a pointer to teardown's line when teardown raises #{klass}" do
        failing["teardown"] = klass.new(message)

        expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)
        expect([stdout.string, File.exist?(out)]).to eq(["#{out}\n", true])
        expect(errors).to eq("quaack: couldn't tear down run #{run_id} (driver_error). #{later}" \
                             "quaack run failed: driver_error. To go on, #{teardown_left}\n")
      end
    end
  end

  it "names the table, column, and type when rewrite-test can't fill a column" do
    column = { "table" => "public.courses", "column" => "tags", "type" => "int4range" }
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "unsupported_type",
                                                                 column:)

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq([1, "#{torn}quaack run failed: unsupported_type: public.courses.tags (int4range)\n"])
  end

  it "tears the run down after an enclave call fails" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")
    cli.run(["run", "--run", run_id, "--out", out])
    expect(transport.calls.last).to eq(["teardown", { args: { run: run_id } }])
  end

  describe "setup, setup" do
    let(:setup) do
      %w[inventory run-server qualify schema-dump statistics volatility classify redact literals clock-anchor
         racetrack-setup]
    end

    it "runs setup first when the run hasn't had it, passing the run-server flags, then the pipeline" do
      entries.merge!(setup_done.transform_values { false }, "inventory" => true)

      status = cli.run(["run", "--run", run_id, "--port", "6432", "--out", out, "--host", "rs-1",
                        "--racetrack-db", "rt", "--arena-db", "ar"])

      expect([status, errors]).to eq([0, torn])
      expect(stderr.string).not_to include("Ignoring")
      expect(transport.calls.map(&:first).take(12)).to eq(%w[version status] + setup.drop(1))
      expect(transport.calls.map(&:first)[12]).to eq("index-feedback")
      expect(transport.calls.to_h["run-server"][:args])
        .to eq(run: run_id, "host" => "rs-1", "port" => "6432", "racetrack-db" => "rt", "arena-db" => "ar")
    end

    it "counts setup's eleven steps in the run's total, before the pipeline's" do
      entries["racetrack_setup"] = false

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      expect(progress.first).to eq("quaack: [1/29] Already done, skipping: " \
                                   "Reading production's version, settings, and extensions (inventory)\n")
      expect(progress).to include("quaack: [11/29] Setting up the racetrack, a copy of production's schema and " \
                                  "statistics (racetrack-setup)\n",
                                  "quaack: [12/29] Already done, skipping: " \
                                  "Checking the query plan and searching for indexes (index-search)\n",
                                  "quaack: [29/29] Writing the report (report)\n")
    end

    it "skips setup, without counting it, when the store says the run has had it" do
      expect(cli.run(["run", "--run", run_id, "--host", "rs-1", "--out", out])).to eq(0)

      expect(transport.calls.map(&:first) & setup).to eq([])
      expect(progress.first).to eq("quaack: [1/18] Already done, skipping: " \
                                   "Checking the query plan and searching for indexes (index-search)\n")
    end

    it "stops at a setup step that fails, prints only its rule, and tears the run down" do
      entries["qualified_query"] = false
      failing["qualify"] = Quaack::Driver::EnclaveError.new(subcommand: "qualify", rule: "unknown_relation",
                                                            sqlstate: "42P01", exit_status: 70)

      status = cli.run(["run", "--run", run_id, "--out", out])

      expect([status, stdout.string, errors]).to eq([1, "", "#{torn}quaack run failed: unknown_relation\n"])
      expect(transport.calls.map(&:first)).to eq(%w[version status qualify teardown])
    end

    it "rejects a repeated run-server flag or one without a value" do
      [["run", "--run", run_id, "--host", "a", "--host", "b"], ["run", "--run", run_id, "--arena-db"]].each do |argv|
        expect(cli.run(argv)).to eq(64)
      end
      expect(errors).to include("quaack run --run <ID> [--rewrites <file>] [--out <path>] [--keep] " \
                                "[--enclave-timeout-seconds <n>] [--host <host>]")
      expect(transport.calls).to eq([])
    end
  end

  it "skips teardown with --keep, in any position, and prints the command to run later" do
    [["--keep", "--out", out], ["--out", out, "--keep"]].each do |options|
      expect(cli.run(["run", "--run", run_id, *options])).to eq(0)
    end
    expect(transport.calls.map(&:first)).not_to include("teardown")
    expect(stdout.string).to eq("#{out}\n#{run_id} done\n" * 2)
    expect(errors).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                         "quaacks teardown --run #{run_id}\n" * 2)
  end

  it "fails with exit 1 and the LLM error's rule and detail when an LLM call fails" do
    fake.error("operator-rewrites", status: 400)

    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])

    expect([status, stdout.string]).to eq([1, ""])
    expect(errors).to start_with("#{torn}quaack run failed: llm_bad_request: ")
    expect(errors).to include("fake invalid_request_error")
  end

  # Task 20261004-66: the run's own error isn't an EnclaveError, and its
  # teardown fails too. The run's error is what to fix, so its message
  # shows as is, with no pointer to teardown's line.
  { "teardown_failed" => [Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "teardown_failed"),
                          "Check or remove ~/.quaack/runs/20260926T010203Z-0123abcd on the jump server by hand."],
    "driver_error" => [IOError.new("sentinel-io-7f3a"), "To tear it down later, run this on the jump server: " \
                                                        "quaacks teardown --run 20260926T010203Z-0123abcd"] }
    .each do |rule, (teardown_error, hint)|
    it "shows the LLM error alone when the run fails and then its teardown fails as #{rule}" do
      fake.error("operator-rewrites", status: 400)
      failing["teardown"] = teardown_error

      status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])

      expect([status, stdout.string]).to eq([1, ""])
      teardown_line, failed_line, *rest = errors.lines
      expect([teardown_line, rest]).to eq(["quaack: couldn't tear down run #{run_id} (#{rule}). #{hint}\n", []])
      # The LLM error's message, which ends with the request's shape in
      # brackets, and nothing after it.
      expect(failed_line).to match(/\Aquaack run failed: llm_bad_request: [^\n]*fake invalid_request_error[^\n]*\]\n\z/)
      expect(errors).not_to include("sentinel-io")
    end
  end

  it "fails with exit 1 when rewrite-payload sends no rewrite payload" do
    replies["rewrite-payload"] = []

    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])

    expect([status, stdout.string, errors]).to eq([1, "", "#{torn}quaack run failed: no_rewrite_payload\n"])
    expect(fake.asks).to eq([])
  end

  it "fails with a usage-style error, before touching the jump server, for a rewrites file that won't parse" do
    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file("SELECT (;\n")])

    expect([status, errors]).to eq([64, "quaack run: the rewrites file doesn't parse\n"])
    expect(transport.calls).to eq([])
  end

  it "fails with a usage-style error for a run this laptop never started" do
    status = cli.run(["run", "--run", "20260926T010203Z-ffffffff"])

    expect([status, stdout.string, errors]).to eq([64, "", "quaack run: unknown run ID\n"])
    expect(transport.calls).to eq([])
  end

  # chmod 000 can't stop root reading, so each example is skipped where
  # the record stays readable. The message names the record by ~, not by
  # its absolute path.
  [[".quaack"], [".quaack", "runs"], [".quaack", "runs", "20260926T010203Z-0123abcd.json"]].each do |parts|
    it "refuses, rather than calling it unknown, a run record it can't read under a mode 000 ~/#{parts.join("/")}" do
      locked = File.join(home, *parts)
      File.chmod(0o000, locked)
      skip "this user can read under mode 000" if File.readable?(File.join(home, ".quaack", "runs", "#{run_id}.json"))

      status = cli.run(["run", "--run", run_id, "--out", out])

      expect([status, stdout.string, errors])
        .to eq([64, "", "quaack run: can't read ~/.quaack/runs/#{run_id}.json (permission denied)\n"])
      expect(transport.calls).to eq([])
    ensure
      File.chmod(0o700, locked) if locked
    end
  end

  it "refuses a run record that isn't a file, rather than calling the run unknown" do
    record = File.join(home, ".quaack", "runs", "#{run_id}.json")
    File.delete(record)
    Dir.mkdir(record)

    expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string, errors])
      .to eq([64, "", "quaack run: can't read ~/.quaack/runs/#{run_id}.json\n"])
    expect(transport.calls).to eq([])
  end

  # Task 20261007-23: the record's JSON is checked, never quoted.
  { "isn't valid JSON" => ["{\"jump_host\": \"sentinel-7f3a", "not valid JSON"],
    "isn't a JSON object" => ['"sentinel-7f3a"', "not a JSON object"],
    "has a jump host that isn't a string" => ['{"jump_host": {"sentinel-7f3a": 1}}',
                                              "jump host isn't a string"] }.each do |what, (text, problem)|
    it "refuses a run record that #{what} as a usage error, naming it by ~" do
      File.write(File.join(home, ".quaack", "runs", "#{run_id}.json"), text)

      expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string, errors])
        .to eq([64, "", "quaack run: can't read ~/.quaack/runs/#{run_id}.json (#{problem})\n"])
      expect(transport.calls).to eq([])
    end
  end

  it "calls the run unknown when ~/.quaack/runs is a file, so no record can be there" do
    runs = File.join(home, ".quaack", "runs")
    FileUtils.rm_rf(runs)
    File.write(runs, "")

    expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string, errors])
      .to eq([64, "", "quaack run: unknown run ID\n"])
    expect(transport.calls).to eq([])
  end

  it "refuses a run record it can't stat for another reason, such as a symlink loop" do
    record = File.join(home, ".quaack", "runs", "#{run_id}.json")
    File.delete(record)
    File.symlink(record, record)

    expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string, errors])
      .to eq([64, "", "quaack run: can't read ~/.quaack/runs/#{run_id}.json\n"])
    expect(transport.calls).to eq([])
  end

  it "fails with a usage-style error, before touching the jump server, for an unreadable rewrites file" do
    status = cli.run(["run", "--run", run_id, "--rewrites", File.join(home, "missing.sql")])

    expect([status, errors]).to eq([64, "quaack run: can't read the rewrites file\n"])
    expect(transport.calls).to eq([])
  end

  it "rejects malformed run options with the usage message" do
    [%w[run], %w[run --run], %w[run --rewrites f], ["run", "--run", run_id, "--rewrites"]].each do |argv|
      expect(cli.run(argv)).to eq(64)
    end
    expect(errors).to include("quaack run --run <ID> [--rewrites <file>]")
    expect(transport.calls).to eq([])
  end

  it "checks the jump server's quaacks version first, and refuses a mismatch, pointing to quaack deploy" do
    replies["version"] = [{ "type" => "version", "version" => "0.0.9" }]
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string]).to eq([1, ""])
    expect(errors).to eq("quaack run failed: jump-1 has quaacks 0.0.9, but this driver needs " \
                         "#{Quaack::Driver::ENCLAVE_VERSION}. Run `quaack deploy --host jump-1`.\n")
    expect(transport.calls.map(&:first)).to eq(["version"])
  end

  it "refuses when the jump server has no quaacks to run, pointing to quaack deploy" do
    failing["version"] = Quaack::Driver::EnclaveError.new(subcommand: "version", rule: "incomplete")
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect(status).to eq(1)
    expect(errors).to eq("quaack run failed: quaacks isn't installed on jump-1, or isn't on PATH for " \
                         "non-interactive ssh there. Run `quaack deploy --host jump-1`.\n")
    expect(transport.calls.map(&:first)).to eq(["version"])
  end

  # Task 20261006-8: a version call that timed out says so.
  it "says a version check that timed out timed out, not that quaacks isn't installed" do
    failing["version"] = Quaack::Driver::EnclaveError.new(subcommand: "version", rule: "timeout", signal: "TERM",
                                                          timeout_seconds: 3600)
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq([1, "quaack run failed: timeout: the enclave call timed out after 1h00m00s; " \
                                       "raise `enclave_timeout_seconds` in ~/.quaack/driver.json, or pass " \
                                       "--enclave-timeout-seconds to quaack run\n"])
  end

  it "names no version it doesn't recognize as one" do
    replies["version"] = [{ "type" => "version", "version" => "x y\n" }]
    cli.run(["run", "--run", run_id, "--out", out])

    expect(errors).to start_with("quaack run failed: jump-1 has quaacks of an unknown version, but")
  end

  it "expects the enclave's own VERSION" do
    expect(Quaack::Driver::ENCLAVE_VERSION).to eq(EnclaveCommands.enclave_version)
  end

  # Task 20261004-10: how long each enclave call may run, from
  # enclave_timeout_seconds in ~/.quaack/driver.json, or --enclave-timeout-seconds.
  describe "the enclave call timeout" do
    let(:timeouts) { [] }
    let(:cli) do
      t = transport
      seen = timeouts
      Quaack::Driver::CLI.new(stdout:, stderr:, home:,
                              transport: lambda { |_host, timeout:|
                                seen << timeout
                                t
                              },
                              client: ->(_settings) { fake.client(burndown: Quaack::Driver::Burndown.new) })
    end

    def write_config(config)
      FileUtils.mkdir_p(File.join(home, ".quaack"))
      File.write(File.join(home, ".quaack", "driver.json"),
                 JSON.generate({ "jump_command" => "echo jump-1", **config }))
    end

    def run_with(*flags) = cli.run(["run", "--run", run_id, "--out", out, *flags])

    it "gives the transport 3600 seconds when nothing sets it" do
      expect(run_with).to eq(0)
      expect(timeouts).to eq([3600])
    end

    it "gives the transport the config's enclave_timeout_seconds" do
      write_config("enclave_timeout_seconds" => 7200)

      expect(run_with).to eq(0)
      expect(timeouts).to eq([7200])
    end

    it "lets --enclave-timeout-seconds override the config" do
      write_config("enclave_timeout_seconds" => 7200)

      expect(run_with("--enclave-timeout-seconds", "90.5")).to eq(0)
      expect(timeouts).to eq([90.5])
    end

    it "takes a --enclave-timeout-seconds of plain digits" do
      expect(run_with("--enclave-timeout-seconds", "90")).to eq(0)
      expect(timeouts).to eq([90.0])
    end

    it "refuses a --enclave-timeout-seconds that isn't a positive number, before touching the jump server" do
      # Task 20261006-8: only plain decimal numbers, not Float()'s other forms.
      %w[0 -5 abc 1e999 0x10 1_000 1e3 .5 5. +5 0.0].each do |value|
        stderr.truncate(0)
        stderr.rewind

        expect([run_with("--enclave-timeout-seconds", value), errors])
          .to eq([64, "quaack run: --enclave-timeout-seconds must be a positive number\n"])
      end
      expect([timeouts, transport.calls]).to eq([[], []])
    end

    it "refuses a config enclave_timeout_seconds that isn't a positive number" do
      path = File.join(home, ".quaack", "driver.json")
      [0, -1, "60", true, nil].each do |value|
        write_config("enclave_timeout_seconds" => value)
        stderr.truncate(0)
        stderr.rewind

        expect([run_with, errors]).to eq([64, "quaack run: bad_driver_config: #{path}: " \
                                              "enclave_timeout_seconds must be a positive number\n"])
      end
      expect(timeouts).to eq([])
    end
  end

  describe "the llm block of ~/.quaack/driver.json" do
    include AnthropicCredentials

    let(:seen) { [] }
    let(:build_client) do
      lambda do |settings|
        seen << settings
        fake.client(burndown: Quaack::Driver::Burndown.new, model: settings.model)
      end
    end
    let(:cli) do
      t = transport
      h = hosts
      Quaack::Driver::CLI.new(stdout:, stderr:, home:, client: build_client,
                              transport: lambda { |host, **|
                                h << host
                                t
                              })
    end
    let(:overrides) do
      { "QUAACK_MODEL" => nil, "QUAACK_LLM_PROVIDER" => nil, "QUAACK_LLM_BASE_URL" => nil, "QUAACK_LLM" => nil }
    end

    def write_config(text)
      FileUtils.mkdir_p(File.join(home, ".quaack"))
      File.write(File.join(home, ".quaack", "driver.json"), text)
    end

    def run_with(env = {}) = with_env(overrides.merge(env)) { cli.run(["run", "--run", run_id, "--out", out]) }

    it "gives the LLM client its settings" do
      write_config(JSON.generate("jump_command" => "echo jump-1",
                                 "llm" => { "model" => "claude-from-config", "api_key_env" => "MY_KEY" }))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "anthropic", model: "claude-from-config", base_url: nil,
                                        api_key_env: "MY_KEY", aws_region: nil, aws_profile: nil,
                                        command_template: nil, timeout_seconds: nil, at: "llm" }])
    end

    it "gives the defaults, with the environment's overrides, when there's no driver.json or no block" do
      run_with("QUAACK_LLM_BASE_URL" => "https://env.example.com")
      write_config(JSON.generate("jump_command" => "echo jump-1"))
      run_with

      expect(seen.map(&:to_h)).to eq([{ provider: "anthropic", model: "claude-opus-5-5",
                                        base_url: "https://env.example.com", api_key_env: nil, aws_region: nil,
                                        aws_profile: nil, command_template: nil, timeout_seconds: nil, at: "llm" },
                                      { provider: "anthropic", model: "claude-opus-5-5", base_url: nil,
                                        api_key_env: nil, aws_region: nil, aws_profile: nil,
                                        command_template: nil, timeout_seconds: nil, at: "llm" }])
    end

    it "fails with a usage error naming the key, not the value, before touching the jump server" do
      write_config(JSON.generate("jump_command" => "echo jump-1",
                                 "llm" => { "provider" => "SENTINEL-VALUE" }))

      expect([run_with, stdout.string, errors])
        .to eq([64, "", "quaack run: llm.provider in ~/.quaack/driver.json must be anthropic, openai_compatible, " \
                        "bedrock, or copilot_cli\n"])
      expect([hosts, transport.calls, seen]).to eq([[], [], []])
    end

    it "fails with a usage error for a bad override" do
      expect([run_with("QUAACK_LLM_PROVIDER" => "SENTINEL-VALUE"), errors])
        .to eq([64, "quaack run: QUAACK_LLM_PROVIDER must be anthropic, openai_compatible, bedrock, or copilot_cli\n"])
      expect(hosts).to eq([])
    end

    it "fails with a usage error for a driver.json that isn't a JSON object" do
      path = File.join(home, ".quaack", "driver.json")

      write_config("{\n  \"jump_command\": \"ok\",\n    SENTINEL-VALUE\n}")
      expect([run_with, errors])
        .to eq([64, "quaack run: bad_driver_config: #{path}: not valid JSON (line 3, column 5)\n"])
      expect(errors).not_to include("SENTINEL-VALUE")
      expect(hosts).to eq([])

      ["[1]", "null"].each do |text|
        write_config(text)
        stderr.truncate(0)
        stderr.rewind

        expect([run_with, errors]).to eq([64, "quaack run: bad_driver_config: #{path}: not a JSON object\n"])
      end
      expect(hosts).to eq([])
    end

    it "fails with a usage error for a driver.json without a valid jump_command" do
      path = File.join(home, ".quaack", "driver.json")

      write_config(JSON.generate("llm" => {}))
      expect([run_with, errors]).to eq([64, "quaack run: bad_driver_config: #{path}: no jump_command\n"])
      expect(hosts).to eq([])

      write_config(JSON.generate("jump_command" => "echo SENTINEL-JUMP\necho jump-1", "llm" => {}))
      stderr.truncate(0)
      stderr.rewind

      expect([run_with, errors])
        .to eq([64, "quaack run: bad_driver_config: #{path}: jump_command isn't one non-blank line\n"])
      expect(errors).not_to include("SENTINEL-JUMP")
      expect(hosts).to eq([])
    end

    # chmod 000 can't stop root reading the file, so the example is
    # skipped where the file stays readable.
    it "fails with a usage error for a driver.json it can't read" do
      write_config(JSON.generate("llm" => {}))
      path = File.join(home, ".quaack", "driver.json")
      File.chmod(0o000, path)
      skip "this user can read a file with mode 000" if File.readable?(path)

      expect([run_with, stdout.string, errors])
        .to eq([64, "", "quaack run: bad_driver_config: #{path}: can't read it (permission denied)\n"])
      expect([hosts, transport.calls, seen]).to eq([[], [], []])
    end

    # The same for a driver.json in a directory it can't read, rather than
    # taking it for a missing driver.json and running with the defaults. A
    # mode 000 ~/.quaack itself stops run sooner, at the run ID lookup in
    # ~/.quaack/runs, so this links driver.json into a directory that is.
    it "fails with a usage error for a driver.json in a directory it can't read" do
      locked = File.join(home, "locked").tap { FileUtils.mkdir_p(it) }
      File.write(File.join(locked, "driver.json"), JSON.generate("llm" => {}))
      File.symlink(File.join(locked, "driver.json"), File.join(home, ".quaack", "driver.json"))
      File.chmod(0o000, locked)
      skip "this user can read a directory with mode 000" if File.readable?(File.join(locked, "driver.json"))

      config_path = File.join(home, ".quaack", "driver.json")
      expect([run_with, stdout.string, stderr.string])
        .to eq([64, "", "quaack run: bad_driver_config: #{config_path}: can't read it (permission denied)\n"])
      expect([hosts, transport.calls, seen]).to eq([[], [], []])
    ensure
      File.chmod(0o700, locked) if locked
    end

    it "gives the client openai_compatible settings" do
      block = { "provider" => "openai_compatible", "model" => "llama-3.3-70b-versatile",
                "base_url" => "https://api.groq.com/openai/v1", "api_key_env" => "GROQ_API_KEY" }
      write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "openai_compatible", model: "llama-3.3-70b-versatile",
                                        base_url: "https://api.groq.com/openai/v1", api_key_env: "GROQ_API_KEY",
                                        aws_region: nil, aws_profile: nil, command_template: nil,
                                        timeout_seconds: nil, at: "llm" }])
    end

    it "gives the client bedrock settings" do
      block = { "provider" => "bedrock", "model" => "us.anthropic.claude-opus-5-5", "aws_region" => "us-west-2",
                "aws_profile" => "quaack-bedrock" }
      write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "bedrock", model: "us.anthropic.claude-opus-5-5", base_url: nil,
                                        api_key_env: nil, aws_region: "us-west-2", aws_profile: "quaack-bedrock",
                                        command_template: nil, timeout_seconds: nil, at: "llm" }])
    end

    it "gives the client copilot_cli settings" do
      template = ["copilot", "--model={model}", "-p", "Read {prompt_file}"]
      block = { "provider" => "copilot_cli", "command_template" => template, "timeout_seconds" => 123 }
      write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "copilot_cli", model: "claude-opus-5.5", base_url: nil,
                                        api_key_env: nil, aws_region: nil, aws_profile: nil,
                                        command_template: template, timeout_seconds: 123, at: "llm" }])
    end

    describe "an llms list" do
      let(:other) { FakeLLM.new }
      let(:build_client) do
        lambda do |settings|
          seen << settings
          (seen.size == 1 ? fake : other).client(burndown: Quaack::Driver::Burndown.new, model: settings.model,
                                                 max_retries: 0)
        end
      end
      let(:llms) do
        [{ "name" => "first", "provider" => "copilot_cli", "model" => "model-one" },
         { "name" => "second", "provider" => "copilot_cli", "model" => "model-two" },
         { "name" => "third", "provider" => "copilot_cli", "model" => "model-three" }]
      end

      def run_rewrites(env = {})
        file = File.join(home, "rewrites.sql")
        File.write(file, "SELECT 2 WHERE $1;\n")
        with_env(overrides.merge(env)) do
          cli.run(["run", "--run", run_id, "--rewrites", file, "--out", out])
        end
      end

      it "builds a client for every entry, in order, and routes the asks across them" do
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms))
        fake.error("operator-rewrites", status: 429)
        other.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

        expect([run_rewrites, errors]).to eq([0, torn])
        expect(seen.map(&:model)).to eq(%w[model-one model-two model-three])
        expect([fake.asks.map(&:step), other.asks.map(&:step)]).to eq([["operator-rewrites"], ["operator-rewrites"]])
        expect(stderr.string).to include("first is rate limited, so the rest of this run skips it; " \
                                         "trying second (operator-rewrites)")
        expect(stderr.string).to include("Asking the LLM (operator-rewrites, second)")
      end

      it "builds only the entries QUAACK_LLM keeps, in its order" do
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms))
        fake.reply("operator-rewrites", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

        expect(run_rewrites("QUAACK_LLM" => "third,first")).to eq(0)
        expect(seen.map(&:model)).to eq(%w[model-three model-one])
      end

      it "fails with a usage error for a bad entry, naming its position, before touching the jump server" do
        write_config(JSON.generate("jump_command" => "echo jump-1",
                                   "llms" => [*llms, { "name" => "SENTINEL-VALUE" }]))

        expect([run_rewrites, stdout.string, errors])
          .to eq([64, "", "quaack run: llms[3].name in ~/.quaack/driver.json must be 1 to 32 lowercase letters, " \
                          "digits, _, or -\n"])
        expect([hosts, transport.calls, seen]).to eq([[], [], []])
      end

      it "fails with a usage error for QUAACK_MODEL with llms, before touching the jump server" do
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms))

        expect([run_rewrites("QUAACK_MODEL" => "m"), errors])
          .to eq([64, "quaack run: QUAACK_MODEL doesn't apply to llms in ~/.quaack/driver.json: use QUAACK_LLM " \
                      "instead\n"])
        expect([hosts, seen]).to eq([[], []])
      end

      it "fails with a usage error for bad llm_routing, before touching the jump server" do
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms,
                                   "llm_routing" => { "mode" => "SENTINEL-VALUE" }))

        expect([run_rewrites, errors])
          .to eq([64, "quaack run: llm_routing.mode in ~/.quaack/driver.json must be round_robin or failover\n"])
        expect([hosts, seen]).to eq([[], []])
      end

      it "stops at an entry whose client can't be built, naming it, after building those before it" do
        failing_build = lambda do |settings|
          seen << settings
          raise Quaack::Driver::LLM::Error.new("llm_auth", "SOME_KEY isn't set") if settings.model == "model-two"

          fake.client(burndown: Quaack::Driver::Burndown.new)
        end
        cli = Quaack::Driver::CLI.new(stdout:, stderr:, home:, client: failing_build, transport: ->(*, **) { raise })
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms))
        status = with_env(overrides) { cli.run(["run", "--run", run_id, "--out", out]) }

        expect([status, stdout.string, errors])
          .to eq([1, "", "quaack run failed: llm_auth: second: SOME_KEY isn't set\n"])
        expect(seen.map(&:model)).to eq(%w[model-one model-two])
      end
    end

    # The CLI's own client builder, not a spec's. build_client takes a
    # transport, so the first example checks what reaches the request. In
    # the second, the CLI builds it with none: the block names a key
    # variable that's unset, so a client built from the block's settings
    # fails with llm_auth before any call, although ANTHROPIC_API_KEY is
    # set. The opt-in lets a client without a transport be built, and turns
    # the network guard off, so NoNetwork.always_refuse keeps it on. The
    # base URL is a closed local port as well.
    context "with the CLI's default client builder" do
      let(:cli) do
        h = hosts
        t = transport
        Quaack::Driver::CLI.new(stdout:, stderr:, home:, transport: lambda { |host, **|
          h << host
          t
        })
      end

      it "builds the client with the settings' model and base_url, on the transport it's given" do
        block = { "model" => "claude-from-block", "base_url" => "https://llm.example.com",
                  "api_key_env" => "QUAACK_SPEC_KEY" }
        settings = Quaack::Driver::LLM.settings(block, env: {})
        client = without_anthropic_credentials("QUAACK_SPEC_KEY" => "fake-key") do
          Quaack::Driver::CLI.build_client(settings, transport: fake)
        end
        fake.reply("llm-rewrites", "ok")
        client.ask(step: "llm-rewrites", messages: [{ role: "user", content: "hi" }], max_tokens: 10)

        expect(fake.asks.map { [it.body[:model], it.url] })
          .to eq([["claude-from-block", "https://llm.example.com/v1/messages"]])
        expect(client.burndown).to be_a(Quaack::Driver::Burndown)
      end

      it "builds an openai_compatible client with the settings' model, base_url, and key variable" do
        openai = FakeOpenAI.new
        block = { "provider" => "openai_compatible", "model" => "model-from-block",
                  "base_url" => "https://api.groq.com/openai/v1", "api_key_env" => "QUAACK_SPEC_KEY" }
        settings = Quaack::Driver::LLM.settings(block, env: {})
        client = with_env("QUAACK_SPEC_KEY" => "fake-key", "OPENAI_API_KEY" => nil) do
          Quaack::Driver::CLI.build_client(settings, transport: openai)
        end
        openai.reply("llm-rewrites", "ok")
        client.ask(step: "llm-rewrites", messages: [{ role: "user", content: "hi" }], max_tokens: 10)

        expect(openai.asks.map { [it.body[:model], it.url] })
          .to eq([["model-from-block", "https://api.groq.com/openai/v1/chat/completions"]])
        expect(client.burndown.llm_calls).to eq("llm-rewrites" => 1)
      end

      it "builds the client from the block's settings" do
        write_config(JSON.generate("jump_command" => "echo jump-1",
                                   "llm" => { "api_key_env" => "QUAACK_SPEC_UNSET_KEY" }))
        env = { "QUAACK_ALLOW_REAL_LLM" => "1", "QUAACK_SPEC_UNSET_KEY" => nil,
                "ANTHROPIC_API_KEY" => "SENTINEL-KEY", "ANTHROPIC_BASE_URL" => "http://127.0.0.1:9" }
        status = without_anthropic_credentials(env) { NoNetwork.always_refuse { run_with } }

        expect([status, stdout.string, errors])
          .to eq([1, "", "quaack run failed: llm_auth: QUAACK_SPEC_UNSET_KEY isn't set\n"])
        expect([hosts, transport.calls]).to eq([[], []])
      end
    end

    context "with the real client builder and no credentials anywhere" do
      let(:build_client) do
        lambda do |settings|
          Quaack::Driver::LLM::Client.new(burndown: Quaack::Driver::Burndown.new, settings:, transport: fake)
        end
      end

      it "fails with exit 1 and llm_auth before touching the jump server" do
        status = without_anthropic_credentials { run_with }

        expect(errors).to start_with("quaack run failed: llm_auth: no Anthropic credentials")
        expect([status, stdout.string]).to eq([1, ""])
        expect([hosts, transport.calls]).to eq([[], []])
      end

      it "prints no key the API quotes back when it refuses one" do
        write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => { "api_key_env" => "QUAACK_SPEC_KEY" }))
        fake.error("operator-rewrites", status: 401, message: "Incorrect API key provided: SENTINEL-KEY")
        status = without_anthropic_credentials("QUAACK_SPEC_KEY" => "SENTINEL-KEY") do
          with_env(overrides) { cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out]) }
        end

        expect(status).to eq(1)
        expect(errors).to include("quaack run failed: llm_auth: the API refused the key (401)")
        expect(stdout.string + stderr.string).not_to include("SENTINEL")
      end

      it "fails the same way for openai_compatible when the variable api_key_env names is unset" do
        block = { "provider" => "openai_compatible", "model" => "m", "api_key_env" => "QUAACK_SPEC_UNSET_KEY" }
        write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))
        status = with_env("QUAACK_SPEC_UNSET_KEY" => nil, "OPENAI_API_KEY" => "SENTINEL-KEY") { run_with }

        expect([status, stdout.string, errors])
          .to eq([1, "", "quaack run failed: llm_auth: QUAACK_SPEC_UNSET_KEY isn't set\n"])
        expect([hosts, transport.calls]).to eq([[], []])
      end

      it "fails the same way for an llms entry, naming it, even when the entry before it is fine" do
        llms = [{ "name" => "opus", "api_key_env" => "QUAACK_SPEC_KEY" },
                { "name" => "groq", "provider" => "openai_compatible", "model" => "m",
                  "api_key_env" => "QUAACK_SPEC_UNSET_KEY" }]
        write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => llms))
        env = { "QUAACK_SPEC_KEY" => "fake-key", "QUAACK_SPEC_UNSET_KEY" => nil, "OPENAI_API_KEY" => "SENTINEL-KEY" }
        status = without_anthropic_credentials(env) { run_with }

        expect([status, stdout.string, errors])
          .to eq([1, "", "quaack run failed: llm_auth: groq: QUAACK_SPEC_UNSET_KEY isn't set\n"])
        expect([hosts, transport.calls]).to eq([[], []])
      end

      describe "for bedrock" do
        include AWSCredentials

        let(:block) { { "provider" => "bedrock", "model" => "us.anthropic.claude-opus-5-5" } }

        it "fails the same way when the AWS chain finds no credentials" do
          llm = block.merge("aws_region" => "us-west-2")
          write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => llm))
          status = without_aws_credentials { run_with }

          expect([status, stdout.string, errors])
            .to eq([1, "", "quaack run failed: llm_auth: #{Quaack::Driver::LLM::BedrockAdapter.no_credentials}\n"])
          expect([hosts, transport.calls]).to eq([[], []])
        end

        it "fails with a usage error when there's no AWS region, before touching the jump server" do
          write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))
          env = { "AWS_ACCESS_KEY_ID" => "AKIAQUAACKSPECENV001", "AWS_SECRET_ACCESS_KEY" => "s" }
          status = without_aws_credentials(env) { run_with }

          expect([status, stdout.string, stderr.string])
            .to eq([64, "", "quaack run: no AWS region for Bedrock: set llm.aws_region in ~/.quaack/driver.json, " \
                            "AWS_REGION, or a region in the AWS profile\n"])
          expect([hosts, transport.calls]).to eq([[], []])
        end

        it "names the llms entry in a usage error from building its client" do
          write_config(JSON.generate("jump_command" => "echo jump-1", "llms" => [block.merge("name" => "bed")]))
          env = { "AWS_ACCESS_KEY_ID" => "AKIAQUAACKSPECENV001", "AWS_SECRET_ACCESS_KEY" => "s" }
          status = without_aws_credentials(env) { run_with }

          expect([status, stdout.string, stderr.string])
            .to eq([64, "", "quaack run: bed: no AWS region for Bedrock: set llms[0].aws_region in " \
                            "~/.quaack/driver.json, AWS_REGION, or a region in the AWS profile\n"])
          expect([hosts, transport.calls]).to eq([[], []])
        end
      end
    end
  end
end
