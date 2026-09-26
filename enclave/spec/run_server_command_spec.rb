# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"
require "tmpdir"
require "quaack/enclave/run_server_command"

# The operator's run_server_command and destroy_command (README, step 4 and
# run teardown), run with /bin/sh on the jump server. Their output is the
# operator's, so an error names only its rule.
RSpec.describe Quaack::Enclave::RunServerCommand do
  let(:dir) { Dir.mktmpdir("quaack-run-server-command") }
  let(:sentinels) { LeakCheck::Sentinels.new }
  let(:good) { { "host" => "rs-1.internal", "port" => 5433, "racetrack_db" => "race", "arena_db" => "arena" } }
  let(:run) { "20260926T010203Z-0123abcd" }

  after { FileUtils.rm_rf(dir) }

  def printing(object) = "printf '%s' #{Shellwords.escape(JSON.generate(object))}"

  def entry(command, server: "prod-1", **)
    described_class.entry(command, server:, run:, **)
  end

  def rule_of
    yield
    raise "expected a RunServer::Error"
  rescue Quaack::Enclave::RunServer::Error => e
    [e.rule, e.cause, e.message.include?(sentinels.word)]
  end

  it "returns the run server entry the command prints" do
    expect(entry(printing(good))).to eq(good)
  end

  it "takes the port as a string of digits too" do
    expect(entry(printing(good.merge("port" => "5433")))["port"]).to eq(5433)
  end

  it "fills {server} and {run} in as single quoted shell words, and runs nothing they hold" do
    pwned = File.join(dir, "pwned")
    server = "a b; touch #{pwned}"
    entry("printf '%s|%s' {server} {run} > #{dir}/args; #{printing(good)}", server:)

    expect(File.read(File.join(dir, "args"))).to eq("#{server}|#{run}")
    expect(File.exist?(pwned)).to be(false)
  end

  it "lets each given override replace the command's value" do
    overrides = { "port" => "6000", "racetrack-db" => "other" }

    expect(entry(printing(good), overrides:)).to eq(good.merge("port" => 6000, "racetrack_db" => "other"))
  end

  it "checks the values the way the flags are checked" do
    expect(rule_of { entry(printing(good.merge("host" => "#{sentinels.word} x"))) })
      .to eq(["bad_run_server_host", nil, false])
    expect(rule_of { entry(printing(good.merge("arena_db" => "race"))) }.first).to eq("run_server_same_database")
    expect(rule_of { entry(printing(good.merge("port" => [1]))) }.first).to eq("bad_run_server_port")
  end

  {
    "isn't JSON" => "echo \"not json\"",
    "isn't an object" => "echo '[1]'",
    "is missing a key" => "echo '{\"host\": \"rs\", \"port\": 1, \"racetrack_db\": \"a\"}'",
    "has an extra key" => "echo '{\"host\": \"rs\", \"port\": 1, \"racetrack_db\": \"a\", \"arena_db\": \"b\", " \
                          "\"x\": 1}'",
    "is too long" => "head -c 100000 /dev/zero | tr '\\0' ' '; echo '{}'"
  }.each do |what, command|
    it "refuses output that #{what} as run_server_command_bad_output" do
      expect(rule_of { entry(command) }.first).to eq("run_server_command_bad_output")
    end
  end

  it "refuses a command that fails, without its output" do
    expect(rule_of { entry("echo #{sentinels.word}; exit 2") }).to eq(["run_server_command_failed", nil, false])
  end

  it "times out a command that runs too long" do
    expect(rule_of { described_class.entry("sleep 5", server: "p", run:, timeout: 0.3) }.first)
      .to eq("run_server_command_timed_out")
  end

  describe ".destroy" do
    it "runs the command with {server} and {run} filled in" do
      described_class.destroy("printf '%s|%s' {server} {run} > #{dir}/gone", server: "prod 1", run:)

      expect(File.read(File.join(dir, "gone"))).to eq("prod 1|#{run}")
    end

    it "fails a failing command as destroy_command_failed" do
      expect(rule_of { described_class.destroy("echo #{sentinels.word}; false", server: "p", run:) })
        .to eq(["destroy_command_failed", nil, false])
    end

    it "times out as destroy_command_timed_out" do
      expect(rule_of { described_class.destroy("sleep 5", server: "p", run:, timeout: 0.3) }.first)
        .to eq("destroy_command_timed_out")
    end
  end
end
