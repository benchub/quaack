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

RSpec.describe "quaack run" do
  let(:home) { Dir.mktmpdir("quaack-cli-run") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:fake) { FakeLLM.new }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:hosts) { [] }
  let(:entries) do
    { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
      "rewrite_rules_applied" => true, "rewrites_generated" => true, "arena_setup" => true, "index_build" => true,
      "baseline" => true,
      "index_baseline" => true, "candidate_runs" => true, "minimax" => true, "result_comparison" => true,
      "selection" => true }
  end
  let(:report) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "verdicts" => {},
      "measurements" => {}, "candidates" => [], "indexes" => {}, "original_plan" => [], "timed_out_count" => 0 }
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
  # transport does while the run goes on.
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
        s.fetch(subcommand, []).each { progress&.call(it) }
        raise f[subcommand] if f.key?(subcommand)

        Data.define(:messages).new(messages: r.fetch(subcommand, []))
      end
    end.new
  end

  let(:cli) do
    t = transport
    h = hosts
    Quaack::Driver::CLI.new(stdout:, stderr:, home:,
                            transport: lambda { |host|
                              h << host
                              t
                            },
                            client: ->(_settings) { fake.client(burndown: Quaack::Driver::Burndown.new) })
  end

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  it "runs the pipeline over ssh to the run's jump host, from arena-setup through the report" do
    entries.transform_values! { false }.merge!("index_search_original" => true, "index_generated_original" => true,
                                               "index_ranking_original" => true, "rewrite_rules_applied" => true,
                                               "rewrites_generated" => true)
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, errors]).to eq([0, torn])
    expect(hosts).to eq(["jump-1"])
    expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback arena-setup status index-build baseline
                                                  index-baseline candidate-runs minimax result-comparison selection
                                                  report-payload teardown])
    expect(transport.calls[1].last[:args]).to eq(run: run_id)
  end

  it "sends the --rewrites file's rewrites through step 7 inside the pipeline, before step 8" do
    file = File.join(home, "rewrites.sql")
    File.write(file, "SELECT 2 WHERE $1;\n")
    fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

    status = cli.run(["run", "--run", run_id, "--rewrites", file, "--out", out])

    expect([status, errors]).to eq([0, torn])
    expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback rewrite-payload rewrite-check status
                                                  status status report-payload teardown])
    expect(transport.calls[4].last[:input]["rewrites"].map { it["sql"] }).to eq(["SELECT 2 WHERE $1"])
    expect(fake.asks.map(&:step)).to eq(["step7"])
  end

  # stderr without its progress lines.
  def errors = stderr.string.lines.grep_v(%r{\Aquaack: \[\d+/\d+\] }).join

  # stderr's progress lines, with each time as Ns.
  def progress = stderr.string.lines.grep(%r{\Aquaack: \[\d+/\d+\] }).map { it.sub(/ in \d+s \(/, " in Ns (") }

  describe "progress on stderr" do
    it "says in plain English what each step does as it starts and ends, numbered, and each skip" do
      entries.transform_values! { false }.merge!("index_search_original" => true, "index_generated_original" => true,
                                                 "index_ranking_original" => true, "rewrites_generated" => true)
      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      steps = [["4b", "Setting up the arena, a second database for test rows"],
               ["steps 9-10", "Testing each rewrite for wrong results"],
               ["step 11", "Asking the LLM for index ideas for each rewrite"],
               ["12a", "Building the candidate indexes"], ["13", "Measuring the original query"],
               ["13a", "Measuring the original query with each set of indexes"], ["14", "Measuring each rewrite"],
               ["14b", "Dropping choices that lose to the original on any literal"],
               ["14c", "Checking that each rewrite returns the same rows on production data"],
               ["14d", "Picking the top three"], ["15", "Writing the report"]]
      expect(progress).to eq(
        ["quaack: [1/18] Already done, skipping: Checking the query plan and searching for indexes (index-search)\n",
         "quaack: [2/18] Already done, skipping: " \
         "Asking the LLM for index ideas the mechanical search missed (5a-5)\n",
         "quaack: [3/18] Asking the LLM to improve its index ideas (5a-6)\n", "quaack: [3/18] Done in Ns (5a-6)\n",
         "quaack: [4/18] Already done, skipping: Ranking the index ideas (5a-7)\n",
         "quaack: [5/18] Applying QUAACK's own rewrite rules to the query (6c)\n", "quaack: [5/18] Done in Ns (6c)\n",
         "quaack: [6/18] Already done, skipping: Asking the LLM for rewrites of the query (6a)\n",
         "quaack: [7/18] Searching for indexes for each rewrite (step 8)\n", "quaack: [7/18] Done in Ns (step 8)\n",
         *steps.each_with_index.flat_map do |(name, description), i|
           ["quaack: [#{8 + i}/18] #{description} (#{name})\n", "quaack: [#{8 + i}/18] Done in Ns (#{name})\n"]
         end]
      )
      expect(stdout.string).to eq("#{out}\n#{run_id} done\n")
    end

    it "counts step 7, and prints each LLM ask and retry, when there's a rewrites file" do
      fake.error("step7", status: 529).reply("step7", { "rewrites" => [{ "transformation" => "t",
                                                                         "assumptions" => [] }] })
      entries["rewrites_generated"] = false
      replies["rewrite-check"] = []
      fake.reply("6a", { "rewrites" => [] })

      expect(cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])).to eq(0)

      expect(progress).to include("quaack: [5/19] Already done, skipping: " \
                                  "Applying QUAACK's own rewrite rules to the query (6c)\n",
                                  "quaack: [6/19] Asking the LLM for rewrites of the query (6a)\n",
                                  "quaack: [6/19] Asking the LLM (6a)\n",
                                  "quaack: [7/19] Checking your own rewrites (step 7)\n",
                                  "quaack: [7/19] Asking the LLM (step7)\n",
                                  "quaack: [7/19] Asking the LLM, attempt 2 (step7)\n",
                                  "quaack: [7/19] Done in Ns (step 7)\n", "quaack: [19/19] Writing the report (15)\n")
    end

    it "prints a step's sub-steps for each rewrite, under the step" do
      entries.merge!("rewrite_1" => true, "index_search_rewrite_1" => true, "index_ranking_rewrite_1" => false,
                     "rewrite_pruned_1" => true, "rewrite_survived_1" => true)

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      skipped = "Rewrite 1: Already done, skipping:"
      expect(progress).to include(
        "quaack: [7/18] #{skipped} Checking the query plan and searching for indexes (index-search)\n",
        "quaack: [7/18] Rewrite 1: Ranking the index ideas (index-rank)\n",
        "quaack: [7/18] #{skipped} Dropping the rewrite if its plan can't win (rewrite-prune)\n",
        "quaack: [9/18] #{skipped} Testing the rewrite for wrong results (steps 9-10)\n"
      )
    end

    it "prints each index 12a builds as the enclave reports it, with its redacted DDL" do
      entries["index_build"] = false
      ddl = "CREATE INDEX quaack_505c95b84989bfd37136 ON public.orders USING btree (id, status) WHERE note = ?"
      streamed["index-build"] = [{ "type" => "index_build_progress", "index" => 1, "total" => 2, "ddl" => ddl },
                                 { "type" => "index_build_progress", "index" => 2, "total" => 2, "ddl" => nil }]

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(0)

      lines = progress.select { it.start_with?("quaack: [11/18]") }
      expect(lines).to eq(["quaack: [11/18] Building the candidate indexes (12a)\n",
                           "quaack: [11/18] Building index 1/2: #{ddl}\n",
                           "quaack: [11/18] Building index 2/2\n",
                           "quaack: [11/18] Done in Ns (12a)\n"])
    end

    it "prints a failed line for the step that fails, before the failure" do
      failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")

      expect(cli.run(["run", "--run", run_id, "--out", out])).to eq(1)

      expect(progress.last).to eq("quaack: [3/18] Failed after 0s (5a-6)\n")
      expect(errors).to eq("#{torn}quaack run failed: arena_missing\n")
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
      fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

      expect(cli.run(["run", "--run", run_id, "--out", out, "--rewrites", rewrites_file])).to eq(0)
      expect(File.exist?(out)).to be(true)
    end
  end

  it "fails with exit 1 and only the rule when an enclave call fails" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string, errors]).to eq([1, "", "#{torn}quaack run failed: arena_missing\n"])
  end

  it "tears the run down after an enclave call fails" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")
    cli.run(["run", "--run", run_id, "--out", out])
    expect(transport.calls.last).to eq(["teardown", { args: { run: run_id } }])
  end

  it "fails with exit 1 and the teardown rule when teardown fails after a good run" do
    failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "teardown_failed")

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string]).to eq([1, ""])
    expect(errors).to eq("quaack: couldn't tear down run #{run_id} (teardown_failed). Check or remove " \
                         "~/.quaack/runs/#{run_id} on the jump server by hand.\n" \
                         "quaack run failed: teardown_failed\n")
  end

  it "skips teardown with --keep, in any position, and prints the command to run later" do
    [["--keep", "--out", out], ["--out", out, "--keep"]].each do |options|
      expect(cli.run(["run", "--run", run_id, *options])).to eq(0)
    end
    expect(transport.calls.map(&:first)).not_to include("teardown")
    expect(errors).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                         "quaacks teardown --run #{run_id}\n" * 2)
  end

  it "fails with exit 1 and the LLM error's rule and detail when an LLM call fails" do
    fake.error("step7", status: 400)

    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file, "--out", out])

    expect([status, stdout.string]).to eq([1, ""])
    expect(errors).to start_with("#{torn}quaack run failed: llm_bad_request: ")
    expect(errors).to include("fake invalid_request_error")
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

  it "names no version it doesn't recognize as one" do
    replies["version"] = [{ "type" => "version", "version" => "x y\n" }]
    cli.run(["run", "--run", run_id, "--out", out])

    expect(errors).to start_with("quaack run failed: jump-1 has quaacks of an unknown version, but")
  end

  it "expects the enclave's own VERSION" do
    expect(Quaack::Driver::ENCLAVE_VERSION).to eq(EnclaveCommands.enclave_version)
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
                              transport: lambda { |host|
                                h << host
                                t
                              })
    end
    let(:overrides) { { "QUAACK_MODEL" => nil, "QUAACK_LLM_PROVIDER" => nil, "QUAACK_LLM_BASE_URL" => nil } }

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
                                        api_key_env: "MY_KEY", aws_region: nil, aws_profile: nil }])
    end

    it "gives the defaults, with the environment's overrides, when there's no driver.json or no block" do
      run_with("QUAACK_LLM_BASE_URL" => "https://env.example.com")
      write_config(JSON.generate("jump_command" => "echo jump-1"))
      run_with

      expect(seen.map(&:to_h)).to eq([{ provider: "anthropic", model: "claude-opus-5-5",
                                        base_url: "https://env.example.com", api_key_env: nil, aws_region: nil,
                                        aws_profile: nil },
                                      { provider: "anthropic", model: "claude-opus-5-5", base_url: nil,
                                        api_key_env: nil, aws_region: nil, aws_profile: nil }])
    end

    it "fails with a usage error naming the key, not the value, before touching the jump server" do
      write_config(JSON.generate("llm" => { "provider" => "SENTINEL-VALUE" }))

      expect([run_with, stdout.string, stderr.string])
        .to eq([64, "", "quaack run: llm.provider in ~/.quaack/driver.json must be anthropic, openai_compatible, " \
                        "or bedrock\n"])
      expect([hosts, transport.calls, seen]).to eq([[], [], []])
    end

    it "fails with a usage error for a bad override" do
      expect([run_with("QUAACK_LLM_PROVIDER" => "SENTINEL-VALUE"), stderr.string])
        .to eq([64, "quaack run: QUAACK_LLM_PROVIDER must be anthropic, openai_compatible, or bedrock\n"])
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
      File.chmod(0o700, locked)
    end

    it "gives the client openai_compatible settings" do
      block = { "provider" => "openai_compatible", "model" => "llama-3.3-70b-versatile",
                "base_url" => "https://api.groq.com/openai/v1", "api_key_env" => "GROQ_API_KEY" }
      write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "openai_compatible", model: "llama-3.3-70b-versatile",
                                        base_url: "https://api.groq.com/openai/v1", api_key_env: "GROQ_API_KEY",
                                        aws_region: nil, aws_profile: nil }])
    end

    it "gives the client bedrock settings" do
      block = { "provider" => "bedrock", "model" => "us.anthropic.claude-opus-5-5", "aws_region" => "us-west-2",
                "aws_profile" => "quaack-bedrock" }
      write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))

      expect(run_with).to eq(0)
      expect(seen.map(&:to_h)).to eq([{ provider: "bedrock", model: "us.anthropic.claude-opus-5-5", base_url: nil,
                                        api_key_env: nil, aws_region: "us-west-2", aws_profile: "quaack-bedrock" }])
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
        Quaack::Driver::CLI.new(stdout:, stderr:, home:, transport: lambda { |host|
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
        fake.reply("6a", "ok")
        client.ask(step: "6a", messages: [{ role: "user", content: "hi" }], max_tokens: 10)

        expect(fake.asks.map { [it.body[:model], it.url] })
          .to eq([["claude-from-block", "https://llm.example.com/v1/messages"]])
        expect(client.burndown).to be_a(Quaack::Driver::Burndown)
      end

      it "builds the client from the block's settings" do
        write_config(JSON.generate("llm" => { "api_key_env" => "QUAACK_SPEC_UNSET_KEY" }))
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

      it "fails the same way for openai_compatible when the variable api_key_env names is unset" do
        block = { "provider" => "openai_compatible", "model" => "m", "api_key_env" => "QUAACK_SPEC_UNSET_KEY" }
        write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => block))
        status = with_env("QUAACK_SPEC_UNSET_KEY" => nil, "OPENAI_API_KEY" => "SENTINEL-KEY") { run_with }

        expect([status, stdout.string, errors])
          .to eq([1, "", "quaack run failed: llm_auth: QUAACK_SPEC_UNSET_KEY isn't set\n"])
        expect([hosts, transport.calls]).to eq([[], []])
      end

      describe "for bedrock" do
        include AWSCredentials

        let(:block) { { "provider" => "bedrock", "model" => "us.anthropic.claude-opus-5-5" } }

        it "fails the same way when the AWS chain finds no credentials" do
          llm = block.merge("aws_region" => "us-west-2")
          write_config(JSON.generate("jump_command" => "echo jump-1", "llm" => llm))
          status = without_aws_credentials { run_with }
          expected = "quaack run failed: llm_auth: no AWS credentials: set AWS_ACCESS_KEY_ID and " \
                     "AWS_SECRET_ACCESS_KEY, name a profile in llm.aws_profile in ~/.quaack/driver.json " \
                     "or AWS_PROFILE, or set AWS_BEARER_TOKEN_BEDROCK\n"

          expect([status, stdout.string, stderr.string]).to eq([1, "", expected])
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
      end
    end
  end
end
