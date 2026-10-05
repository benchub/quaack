# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "quaack/driver/transport"

# The ssh transport, run through a fake ssh (see EnclaveCommands.fake_ssh)
# that does what ssh and the jump server's shell do with a command: join
# its words with spaces and hand the string to `sh -c`. So these prove the
# quoting holds without a real ssh server. The remote quaacks is CLI.main
# with a test step that returns the argv and input it got.
RSpec.describe Quaack::Driver::Transport::Ssh do
  let(:dir) { Dir.mktmpdir("quaack-driver-ssh") }
  let(:pwned) { File.join(dir, "pwned") }
  let(:ssh) { EnclaveCommands.fake_ssh(dir, remote_bin: File.join(dir, "remote-bin")) }
  # Arguments a shell would split, expand, or run, if they weren't quoted.
  let(:tricky) do
    ["a b", %('single' "double"), "semi; touch #{pwned}", "$(touch #{pwned})", "`touch #{pwned}`",
     "a && touch #{pwned}", "a | touch #{pwned}", "back\\slash", "new\nline", "tab\there", "*", "~", "$HOME",
     "!x", "", "--run", "é ✓", "a'b\"c", "#comment", "{a,b}", "'", "\""]
  end
  let(:options) { tricky.each_index.to_h { ["v#{it}", :value] } }

  after { FileUtils.rm_rf(dir) }

  # Puts the echo step on the fake jump server's PATH as quaacks.
  def echo_quaacks
    command = EnclaveCommands.probe(dir, "[{ type: :version, version: JSON.generate([ARGV, inputs[:input]]) }]",
                                    input: true, options:)
    EnclaveCommands.remote_quaacks(File.join(dir, "remote-bin"), command)
  end

  def echoed(result) = JSON.parse(result.messages.first.fetch("version"))

  it "passes every argument to the remote quaacks intact, and runs none of them" do
    echo_quaacks
    args = tricky.each_with_index.to_h { |value, i| ["v#{i}", value] }

    argv, = echoed(described_class.new(host: "jump-1.example", ssh:).call("probe", args:, input: {}))

    expect(argv).to eq(["probe", *tricky.each_with_index.flat_map { |value, i| ["--v#{i}", value] }])
    expect(File.exist?(pwned)).to be(false)
  end

  it "pipes input to the remote quaacks on stdin, as JSON" do
    echo_quaacks
    input = { "query" => "SELECT '$(touch #{pwned})'; -- `x`\n", "n" => [1, nil, true] }

    _, got = echoed(described_class.new(host: "jump-1.example", ssh:).call("probe", input:))

    expect(got).to eq(input)
    expect(File.exist?(pwned)).to be(false)
  end

  it "hands the call's block each progress message while the remote step is still running" do
    go = File.join(dir, "go")
    body = "inputs[:progress].call(type: :index_build_progress, index: 1, total: 1, ddl: 'd'); " \
           "sleep 0.01 until File.exist?(#{go.inspect}); []"
    EnclaveCommands.remote_quaacks(File.join(dir, "remote-bin"), EnclaveCommands.probe(dir, body, progress: true))
    seen = []

    result = described_class.new(host: "jump-1", ssh:, timeout: 20).call("probe") do |message|
      seen << message
      File.write(go, "")
    end

    expect(seen).to eq([{ "type" => "index_build_progress", "index" => 1, "total" => 1, "ddl" => "d" }])
    expect(result.messages).to eq([])
  end

  it "runs ssh with its options, then --, then the host, then the remote command as one quoted string" do
    echo_quaacks
    described_class.new(host: "user@jump-1.example", ssh:).call("probe", args: { "v0" => "a b" }, input: {})

    expect(EnclaveCommands.ssh_argv(dir))
      .to eq(["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4",
              "-o", "ConnectTimeout=30", "--", "user@jump-1.example", "quaacks probe --v0 a\\ b"])
  end

  it "passes the options it's given in place of the defaults" do
    echo_quaacks
    described_class.new(host: "jump-1.example", ssh:, options: ["-o", "ConnectTimeout=5"]).call("probe", input: {})

    expect(EnclaveCommands.ssh_argv(dir)).to eq(["-o", "ConnectTimeout=5", "--", "jump-1.example", "quaacks probe"])
  end

  it "refuses a host that ssh could read as an option, or that isn't one word" do
    ["-oProxyCommand=touch #{pwned}", "-p2222", "-v", "", "a b", "jump\n", "a;b", nil, :jump].each do |host|
      expect { described_class.new(host:, ssh:) }.to raise_error(ArgumentError), "for #{host.inspect}"
    end
  end

  it "refuses options that aren't an Array of Strings" do
    ["-T", [:T], [nil], nil].each do |bad|
      expect do
        described_class.new(host: "jump", ssh:, options: bad)
      end.to raise_error(ArgumentError), "for #{bad.inspect}"
    end
  end

  it "refuses an ssh that isn't a command name or path" do
    [nil, "", 1, ["ssh"], "ss\0h"].each do |bad|
      expect { described_class.new(host: "jump", ssh: bad) }.to raise_error(ArgumentError), "for #{bad.inspect}"
    end
  end

  it "keeps its own copy of the options" do
    echo_quaacks
    options = ["-o", "ConnectTimeout=5"]
    transport = described_class.new(host: "jump-1.example", ssh:, options:)
    options.replace(["-o", "Changed=1"])
    transport.call("probe", input: {})

    expect(EnclaveCommands.ssh_argv(dir)).to eq(["-o", "ConnectTimeout=5", "--", "jump-1.example", "quaacks probe"])
  end

  # Shellwords writes a newline as three bytes, so argv that fits
  # MAX_ARGV_BYTES can still make a remote command past it. The ssh here
  # doesn't exist, so a call that got past the check would fail as
  # not_started instead.
  it "refuses a remote command whose quoted form holds more than MAX_ARGV_BYTES, before running ssh" do
    max = Quaack::Driver::Transport::Base::MAX_ARGV_BYTES
    value = "\n" * (max / 2)
    transport = described_class.new(host: "jump-1.example", ssh: File.join(dir, "no-ssh"))

    expect { transport.call("probe", args: { query: value }) }
      .to raise_error(ArgumentError, /remote command holds more than #{max} bytes/)
  end

  it "fails as not_started when there's no ssh to run" do
    expect { described_class.new(host: "jump", ssh: File.join(dir, "no-ssh")).call("version") }
      .to raise_error(Quaack::Driver::EnclaveError, "quaacks version failed: not_started")
  end

  describe "when ssh exits 255" do
    let(:log) { File.join(dir, "ssh-log") }
    let(:sentinel) { "sentinel-20261004-21-probe" }

    # A fake ssh that logs each run's argv, answers the probe (remote
    # command true) with a sentinel on stdout and stderr and probe_exit,
    # and runs call, shell, for anything else.
    def scripted_ssh(call, probe_exit:)
      path = File.join(dir, "scripted-ssh")
      File.write(path, <<~SH)
        #!/bin/sh
        for last; do :; done
        printf '%s\\037' "$@" >> '#{log}'; echo >> '#{log}'
        if [ "$last" = true ]; then echo '#{sentinel}'; echo '#{sentinel}' >&2; exit #{probe_exit}; fi
        #{call}
      SH
      FileUtils.chmod(0o755, path)
      path
    end

    # Each run of the fake ssh, as its argv.
    def runs = File.readlines(log, chomp: true).map { it.split("\037") }

    def failure(ssh, options: ["-o", "ConnectTimeout=5"])
      described_class.new(host: "jump-1", ssh:, options:).call("version")
    rescue Quaack::Driver::EnclaveError => e
      e
    end

    it "fails as ssh_failed when it printed nothing and a probe that runs no quaacks can't ssh either" do
      error = failure(scripted_ssh("exit 255", probe_exit: 255))

      expect(error.message).to eq("quaacks version failed: ssh_failed (exit 255)")
      expect(runs).to eq([["-o", "ConnectTimeout=5", "--", "jump-1", "quaacks version"],
                          ["-o", "ConnectTimeout=5", "--", "jump-1", "true"]])
    end

    it "stays incomplete when it printed nothing but the probe gets through, as for a killed remote process" do
      error = failure(scripted_ssh("exit 255", probe_exit: 0))

      expect(error.message).to eq("quaacks version failed: incomplete (exit 255)")
      expect(runs.size).to eq(2)
    end

    it "runs no probe when the call printed anything, even a partial line" do
      error = failure(scripted_ssh("printf '{\"type\":\"ver'; exit 255", probe_exit: 255))

      expect(error.message).to eq("quaacks version failed: incomplete (exit 255)")
      expect(runs.size).to eq(1)
    end

    it "runs no probe when the call exits other than 255" do
      error = failure(scripted_ssh("exit 1", probe_exit: 255))

      expect(error.message).to eq("quaacks version failed: incomplete (exit 1)")
      expect(runs.size).to eq(1)
    end

    it "keeps nothing the probe printed" do
      [255, 0].each do |probe_exit|
        error = failure(scripted_ssh("exit 255", probe_exit:))

        expect(error.full_message(highlight: false)).not_to include(sentinel)
        expect(error.rule_with_note).not_to include(sentinel)
      end
    end

    # Planted, so the check above is known to catch a sentinel.
    it "would catch the sentinel if it got into an error" do
      planted = Quaack::Driver::EnclaveError.new(subcommand: "version #{sentinel}", rule: "ssh_failed")

      expect(planted.full_message(highlight: false)).to include(sentinel)
    end
  end
end
