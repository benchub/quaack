# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/cli"
require "quaack/driver/runs"
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
      "rewrites_generated" => true, "arena_setup" => true, "index_build" => true, "baseline" => true,
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
  let(:transport) do
    r = replies
    f = failing
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
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
                            client: -> { fake.client(burndown: Quaack::Driver::Burndown.new) })
  end

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  it "runs the pipeline over ssh to the run's jump host, from arena-setup through the report" do
    entries.transform_values! { false }.merge!("index_search_original" => true, "index_generated_original" => true,
                                               "index_ranking_original" => true, "rewrites_generated" => true)
    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stderr.string]).to eq([0, torn])
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

    expect([status, stderr.string]).to eq([0, torn])
    expect(transport.calls.map(&:first)).to eq(%w[version status index-feedback rewrite-payload rewrite-check status
                                                  status status report-payload teardown])
    expect(transport.calls[4].last[:input]["rewrites"].map { it["sql"] }).to eq(["SELECT 2 WHERE $1"])
    expect(fake.asks.map(&:step)).to eq(["step7"])
  end

  def rewrites_file(text = "SELECT 2 WHERE $1;\n")
    File.join(home, "rewrites.sql").tap { File.write(it, text) }
  end

  it "prints the run ID and done on success" do
    expect([cli.run(["run", "--run", run_id, "--out", out]), stdout.string]).to eq([0, "#{out}\n#{run_id} done\n"])
  end

  context "when selection is stored" do
    it "writes the report to --out and prints its path before done" do
      expect([cli.run(["run", "--run", run_id, "--out", out]), stderr.string]).to eq([0, torn])
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

    status = cli.run(["run", "--run", run_id])

    expect([status, stdout.string, stderr.string]).to eq([1, "", "#{torn}quaack run failed: arena_missing\n"])
  end

  it "tears the run down after an enclave call fails" do
    failing["index-feedback"] = Quaack::Driver::EnclaveError.new(subcommand: "index-feedback", rule: "arena_missing")
    cli.run(["run", "--run", run_id])
    expect(transport.calls.last).to eq(["teardown", { args: { run: run_id } }])
  end

  it "fails with exit 1 and the teardown rule when teardown fails after a good run" do
    failing["teardown"] = Quaack::Driver::EnclaveError.new(subcommand: "teardown", rule: "teardown_failed")

    status = cli.run(["run", "--run", run_id, "--out", out])

    expect([status, stdout.string]).to eq([1, ""])
    expect(stderr.string).to eq("quaack: couldn't tear down run #{run_id} (teardown_failed). Check or remove " \
                                "~/.quaack/runs/#{run_id} on the jump server by hand.\n" \
                                "quaack run failed: teardown_failed\n")
  end

  it "skips teardown with --keep, in any position, and prints the command to run later" do
    [["--keep", "--out", out], ["--out", out, "--keep"]].each do |options|
      expect(cli.run(["run", "--run", run_id, *options])).to eq(0)
    end
    expect(transport.calls.map(&:first)).not_to include("teardown")
    expect(stderr.string).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                                "quaacks teardown --run #{run_id}\n" * 2)
  end

  it "fails with exit 1 and only the rule when an LLM call fails" do
    fake.error("step7", status: 401)

    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file])

    expect([status, stdout.string, stderr.string]).to eq([1, "", "#{torn}quaack run failed: llm_auth\n"])
  end

  it "fails with exit 1 when rewrite-payload sends no rewrite payload" do
    replies["rewrite-payload"] = []

    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file])

    expect([status, stdout.string, stderr.string]).to eq([1, "", "#{torn}quaack run failed: no_rewrite_payload\n"])
    expect(fake.asks).to eq([])
  end

  it "fails with a usage-style error, before touching the jump server, for a rewrites file that won't parse" do
    status = cli.run(["run", "--run", run_id, "--rewrites", rewrites_file("SELECT (;\n")])

    expect([status, stderr.string]).to eq([64, "quaack run: the rewrites file doesn't parse\n"])
    expect(transport.calls).to eq([])
  end

  it "fails with a usage-style error for a run this laptop never started" do
    status = cli.run(["run", "--run", "20260926T010203Z-ffffffff"])

    expect([status, stdout.string, stderr.string]).to eq([64, "", "quaack run: unknown run ID\n"])
    expect(transport.calls).to eq([])
  end

  it "fails with a usage-style error, before touching the jump server, for an unreadable rewrites file" do
    status = cli.run(["run", "--run", run_id, "--rewrites", File.join(home, "missing.sql")])

    expect([status, stderr.string]).to eq([64, "quaack run: can't read the rewrites file\n"])
    expect(transport.calls).to eq([])
  end

  it "rejects malformed run options with the usage message" do
    [%w[run], %w[run --run], %w[run --rewrites f], ["run", "--run", run_id, "--rewrites"]].each do |argv|
      expect(cli.run(argv)).to eq(64)
    end
    expect(stderr.string).to include("quaack run --run <ID> [--rewrites <file>]")
    expect(transport.calls).to eq([])
  end

  it "checks the jump server's quaacks version first, and refuses a mismatch, pointing to quaack deploy" do
    replies["version"] = [{ "type" => "version", "version" => "0.0.9" }]
    status = cli.run(["run", "--run", run_id])

    expect([status, stdout.string]).to eq([1, ""])
    expect(stderr.string).to eq("quaack run failed: jump-1 has quaacks 0.0.9, but this driver needs " \
                                "#{Quaack::Driver::ENCLAVE_VERSION}. Run `quaack deploy --host jump-1`.\n")
    expect(transport.calls.map(&:first)).to eq(["version"])
  end

  it "refuses when the jump server has no quaacks to run, pointing to quaack deploy" do
    failing["version"] = Quaack::Driver::EnclaveError.new(subcommand: "version", rule: "incomplete")
    status = cli.run(["run", "--run", run_id])

    expect(status).to eq(1)
    expect(stderr.string).to eq("quaack run failed: quaacks isn't installed on jump-1, or isn't on PATH for " \
                                "non-interactive ssh there. Run `quaack deploy --host jump-1`.\n")
    expect(transport.calls.map(&:first)).to eq(["version"])
  end

  it "names no version it doesn't recognize as one" do
    replies["version"] = [{ "type" => "version", "version" => "x y\n" }]
    cli.run(["run", "--run", run_id])

    expect(stderr.string).to start_with("quaack run failed: jump-1 has quaacks of an unknown version, but")
  end

  it "expects the enclave's own VERSION" do
    expect(Quaack::Driver::ENCLAVE_VERSION).to eq(EnclaveCommands.enclave_version)
  end
end
