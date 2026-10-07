# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "quaack/driver/cli"
require "quaack/driver/enclave_error"
require "quaack/driver/runs"

# `quaack setup --run <ID>`: DESIGN.md setup over ssh to the run's
# jump server. ssh is the edge, so the transport is a fake that records
# each call.
RSpec.describe "quaack setup" do
  let(:home) { Dir.mktmpdir("quaack-cli-setup") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:hosts) { [] }
  let(:timeouts) { [] }
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
    seen = timeouts
    Quaack::Driver::CLI.new(stdout:, stderr:, home:, transport: lambda { |host, **options|
      h << host
      seen << options[:timeout]
      t
    })
  end

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  def subcommands = transport.calls.map(&:first)
  def progress = stderr.string.lines.grep(%r{\Aquaack: \[\d+/\d+\] })
  def errors = stderr.string.lines.grep_v(%r{\Aquaack: \[\d+/\d+\] }).join

  it "runs setup in order on the run's jump host, then says the run is set up" do
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

  it "says when ssh couldn't reach the jump server, and the command that resumes setup" do
    failing["qualify"] = Quaack::Driver::EnclaveError.new(subcommand: "qualify", rule: "ssh_failed", exit_status: 255)

    expect(cli.run(["setup", "--run", run_id])).to eq(1)

    expect(errors).to eq("quaack setup failed: ssh_failed: couldn't ssh to the jump server; check your ssh login " \
                         "or network, then resume with `quaack setup --run #{run_id}`\n")
  end

  # Task 20261004-26: setup never tears down, so the run is there to resume.
  it "says to resume setup after an incomplete call" do
    failing["qualify"] = Quaack::Driver::EnclaveError.new(subcommand: "qualify", rule: "incomplete", exit_status: 1)

    expect(cli.run(["setup", "--run", run_id])).to eq(1)

    expect(errors).to eq("quaack setup failed: incomplete: quaacks qualify ended with exit 1. " \
                         "To go on, resume with `quaack setup --run #{run_id}`\n")
  end

  it "says to start a new run when an older version of QUAACK started this one" do
    failing["status"] = Quaack::Driver::EnclaveError.new(subcommand: "status", rule: "run_from_older_version",
                                                         exit_status: 64)

    expect(cli.run(["setup", "--run", run_id])).to eq(1)

    expect(errors).to eq("quaack setup failed: run_from_older_version: an older version of QUAACK started this run, " \
                         "and this version can't resume it. Start a new run with quaack start.\n")
  end

  # Task 20261004-17: the note names the jump host and production server
  # from the laptop's record of the run.
  describe "a connection failure" do
    let(:libpq) do
      "your libpq setup on the jump server: PG* environment variables, ~/.pg_service.conf with PGSERVICE, and " \
        "~/.pgpass. A non-interactive ssh session may not load the shell rc file that sets them."
    end

    def fail_inventory(rule)
      failing["inventory"] = Quaack::Driver::EnclaveError.new(subcommand: "inventory", rule:, exit_status: 70)
      expect(cli.run(["setup", "--run", run_id])).to eq(1)
    end

    it "names production and the jump host, says where the rest comes from, and how to resume" do
      Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1")
      fail_inventory("production_connection_failed")

      expect(errors).to eq("quaack setup failed: production_connection_failed: couldn't connect to production at " \
                           "prod-1. QUAACK gives libpq only that host. The port, user, database, and password come " \
                           "from #{libpq} Test it with `ssh jump-1 'psql -h prod-1 -c \"select 1\"'`. If production " \
                           "listens on another port than your libpq setup gives, start a new run with `quaack start " \
                           "--port <n>`. Otherwise fix your libpq setup, then resume with `quaack setup --run " \
                           "#{run_id}`\n")
    end

    # Task 20261004-37: the port quaack start recorded goes into the test
    # command exactly.
    it "gives psql the port quaack start recorded" do
      Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1", port: "6543")
      fail_inventory("production_connection_failed")

      expect(errors).to start_with("quaack setup failed: production_connection_failed: couldn't connect to " \
                                   "production at prod-1, port 6543. ")
      expect(errors).to include("Test it with `ssh jump-1 'psql -h prod-1 -p 6543 -c \"select 1\"'`.")
    end

    it "says the production server you gave quaack start for a run recorded without one" do
      fail_inventory("production_connection_failed")

      expect(errors).to start_with("quaack setup failed: production_connection_failed: couldn't connect to the " \
                                   "production server you gave quaack start. ")
      expect(errors).to include("Test it with `ssh jump-1 'psql -h <server> -c")
    end

    # Task 20261004-63: such a record is a driver before 0.1.6's, which
    # gave intake quaack start --port without recording it.
    it "says the port may be quaack start --port's for a run recorded without the server" do
      fail_inventory("production_connection_failed")

      expect(errors).to include("QUAACK gives libpq only that host, and the port you gave `quaack start --port`, " \
                                "if you gave one. The user, database, and password, and the port if you gave no " \
                                "--port, come from ")
      expect(errors).to include("`ssh jump-1 'psql -h <server> -c \"select 1\"'`, adding `-p <n>` if you gave " \
                                "`quaack start --port`.")
    end

    # Task 20261004-40: a hand-edited record with a valid port but an
    # invalid server gives no half-filled-in psql command.
    it "leaves -p out of the test command when the recorded server isn't valid" do
      Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1", port: "6543")
      path = File.join(home, ".quaack", "runs", "#{run_id}.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("server" => "-bad host")))
      fail_inventory("production_connection_failed")

      expect(errors).to include("Test it with `ssh jump-1 'psql -h <server> -c \"select 1\"'`.")
      expect(errors).not_to include("-p 6543")
    end

    it "names the jump host for the run server's, and how to resume" do
      Quaack::Driver::Runs.new(home).record(run_id, "jump-1", server: "prod-1")
      failing["racetrack-setup"] = Quaack::Driver::EnclaveError.new(subcommand: "racetrack-setup",
                                                                    rule: "run_server_connection_failed",
                                                                    exit_status: 70)

      expect(cli.run(["setup", "--run", run_id])).to eq(1)
      expect(errors).to start_with("quaack setup failed: run_server_connection_failed: couldn't connect to the " \
                                   "run server. ")
      expect(errors).to end_with("Test it with `ssh jump-1 'psql -h <host> -p <port> -d <racetrack db> -c " \
                                 "\"select 1\"'`. Then resume with `quaack setup --run #{run_id}`\n")
    end
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

  # Task 20261006-8: setup's enclave calls get enclave_timeout_seconds from
  # ~/.quaack/driver.json too, so a timeout's note, which says to raise it,
  # holds for setup.
  describe "the enclave call timeout" do
    def write_config(config)
      FileUtils.mkdir_p(File.join(home, ".quaack"))
      File.write(File.join(home, ".quaack", "driver.json"),
                 JSON.generate({ "jump_command" => "echo jump-1", **config }))
    end

    it "gives the transport 3600 seconds when nothing sets it" do
      expect(cli.run(["setup", "--run", run_id])).to eq(0)
      expect(timeouts).to eq([3600])
    end

    it "gives the transport the config's enclave_timeout_seconds" do
      write_config("enclave_timeout_seconds" => 7200)

      expect(cli.run(["setup", "--run", run_id])).to eq(0)
      expect(timeouts).to eq([7200])
    end

    it "refuses a config enclave_timeout_seconds that isn't a positive number, before touching the jump server" do
      write_config("enclave_timeout_seconds" => 0)
      path = File.join(home, ".quaack", "driver.json")

      expect([cli.run(["setup", "--run", run_id]), errors])
        .to eq([64, "quaack setup: bad_driver_config: #{path}: enclave_timeout_seconds must be a positive number\n"])
      expect([timeouts, transport.calls]).to eq([[], []])
    end
  end
end
