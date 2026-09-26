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
      "rewrites_generated" => true }
  end
  let(:replies) do
    { "status" => [{ "type" => "status", "entries" => entries }],
      "index-payload" => [{ "type" => "index_payload" }],
      "index-feedback" => [{ "type" => "index_feedback", "revise" => false, "refined" => false }],
      "rewrite-payload" => [{ "type" => "rewrite_payload", "query" => "SELECT $1" }],
      "rewrite-check" => [{ "type" => "rewrite_outcome", "index" => 0, "outcome" => "accepted" }] }
  end

  # Stands in for ssh, at the edge: records each call.
  let(:transport) do
    r = replies
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
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

  it "runs the pipeline over ssh to the run's jump host" do
    status = cli.run(["run", "--run", run_id])

    expect([status, stderr.string]).to eq([0, ""])
    expect(hosts).to eq(["jump-1"])
    expect(transport.calls.map(&:first)).to eq(%w[status index-payload index-feedback])
    expect(transport.calls.first.last[:args]).to eq(run: run_id)
  end

  it "sends the --rewrites file's rewrites through step 7 after the pipeline" do
    file = File.join(home, "rewrites.sql")
    File.write(file, "SELECT 2 WHERE $1;\n")
    fake.reply("step7", { "rewrites" => [{ "transformation" => "t", "assumptions" => [] }] })

    status = cli.run(["run", "--run", run_id, "--rewrites", file])

    expect([status, stderr.string]).to eq([0, ""])
    expect(transport.calls.map(&:first).last(2)).to eq(%w[rewrite-payload rewrite-check])
    expect(transport.calls.last.last[:input]["rewrites"].map { it["sql"] }).to eq(["SELECT 2 WHERE $1"])
    expect(fake.asks.map(&:step)).to eq(["step7"])
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
end
