# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/cli"
require "quaack/driver/enclave_error"
require "quaack/driver/runs"

# `quaack setup --run <ID>`: DESIGN.md steps 2 to 4a over ssh to the run's
# jump server. ssh is the edge, so the transport is a fake that records
# each call.
RSpec.describe "quaack setup" do
  let(:home) { Dir.mktmpdir("quaack-cli-setup") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:hosts) { [] }
  let(:order) do
    %w[inventory run-server qualify schema-dump statistics volatility classify redact literals clock-anchor
       racetrack-setup]
  end
  let(:entries) { {} }
  let(:failing) { {} }
  let(:enclave_version) { Quaack::Driver::ENCLAVE_VERSION }
  let(:transport) do
    replies = { "version" => [{ "type" => "version", "version" => enclave_version }],
                "status" => [{ "type" => "status", "entries" => entries }] }
    f = failing
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        raise f[subcommand] if f.key?(subcommand)

        Data.define(:messages).new(messages: replies.fetch(subcommand, []))
      end
    end.new
  end
  let(:cli) do
    t = transport
    h = hosts
    Quaack::Driver::CLI.new(stdout:, stderr:, home:, transport: lambda { |host|
      h << host
      t
    })
  end

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  def subcommands = transport.calls.map(&:first)
  def progress = stderr.string.lines.grep(%r{\Aquaack: \[\d+/\d+\] })
  def errors = stderr.string.lines.grep_v(%r{\Aquaack: \[\d+/\d+\] }).join

  it "runs steps 2 to 4a in order on the run's jump host, then says the run is set up" do
    expect(cli.run(["setup", "--run", run_id])).to eq(0)

    expect(hosts).to eq(["jump-1"])
    expect(subcommands).to eq(%w[version status] + order)
    expect(transport.calls.drop(1).map { it.last[:args] }).to all(eq(run: run_id))
    expect([stdout.string, errors]).to eq(["#{run_id} set up\n", ""])
  end

  it "prints each step as it runs, numbered out of eleven" do
    cli.run(["setup", "--run", run_id])

    expect(progress.grep_v(/Done in/).map { it[%r{\[\d+/\d+\]}] }).to eq((1..11).map { "[#{it}/11]" })
    expect(progress.first).to eq("quaack: [1/11] Reading production's version, settings, and extensions (inventory)\n")
    expect(progress.grep(/Done in/).size).to eq(11)
  end

  it "passes the run-server flags, in any order, to run-server" do
    status = cli.run(["setup", "--run", run_id, "--arena-db", "ar", "--host", "rs-1", "--racetrack-db", "rt",
                      "--port", "6432"])

    expect(status).to eq(0)
    expect(transport.calls.to_h["run-server"][:args])
      .to eq(run: run_id, "host" => "rs-1", "port" => "6432", "racetrack-db" => "rt", "arena-db" => "ar")
  end

  it "passes only the flags given, so run-server takes the rest from run_server_command" do
    cli.run(["setup", "--run", run_id, "--host", "rs-1"])

    expect(transport.calls.to_h["run-server"][:args]).to eq(run: run_id, "host" => "rs-1")
  end

  it "skips the steps the store says are done" do
    entries.merge!("inventory" => true, "run_server" => true)

    expect(cli.run(["setup", "--run", run_id])).to eq(0)

    expect(subcommands).to eq(%w[version status] + order.drop(2))
    expect(progress.first).to eq("quaack: [1/11] Already done, skipping: " \
                                 "Reading production's version, settings, and extensions (inventory)\n")
  end

  it "stops at a failing step, prints only its rule, and keeps the run" do
    failing["qualify"] = Quaack::Driver::EnclaveError.new(subcommand: "qualify", rule: "unknown_relation",
                                                          sqlstate: "42P01", exit_status: 70)

    expect(cli.run(["setup", "--run", run_id])).to eq(1)

    expect(subcommands).to eq(%w[version status inventory run-server qualify])
    expect([stdout.string, errors]).to eq(["", "quaack setup failed: unknown_relation\n"])
  end

  it "says to start a new run when an older version of QUAACK started this one" do
    failing["status"] = Quaack::Driver::EnclaveError.new(subcommand: "status", rule: "run_from_older_version",
                                                         exit_status: 64)

    expect(cli.run(["setup", "--run", run_id])).to eq(1)

    expect(errors).to eq("quaack setup failed: run_from_older_version: an older version of QUAACK started this run, " \
                         "and this version can't resume it. Start a new run with quaack start.\n")
  end

  context "with another quaacks version on the jump server" do
    let(:enclave_version) { "0.0.9" }

    it "refuses before any step, pointing to quaack deploy" do
      expect(cli.run(["setup", "--run", run_id])).to eq(1)

      expect(subcommands).to eq(%w[version])
      expect(errors).to eq("quaack setup failed: jump-1 has quaacks 0.0.9, but this driver needs " \
                           "#{Quaack::Driver::ENCLAVE_VERSION}. Run `quaack deploy --host jump-1`.\n")
    end
  end

  it "refuses an unknown run ID as a usage error" do
    expect(cli.run(["setup", "--run", "20260926T010203Z-ffffffff"])).to eq(64)

    expect([hosts, errors]).to eq([[], "quaack setup: unknown run ID\n"])
  end

  it "rejects a missing --run, an unknown option, a repeated one, or one without a value" do
    [["setup"], ["setup", "--run", run_id, "--rewrites", "f"], ["setup", "--run", run_id, "--host", "a", "--host", "b"],
     ["setup", "--run", run_id, "--host"], ["setup", "--host", "a", "--run", run_id]].each do |argv|
      expect(cli.run(argv)).to eq(64), argv.inspect
    end
    expect(hosts).to eq([])
    expect(stderr.string).to include("quaack setup --run <ID> [--host <host>] [--port <port>]")
  end
end
