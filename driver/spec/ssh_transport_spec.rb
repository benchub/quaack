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

  it "runs ssh with its options, then --, then the host, then the remote command as one quoted string" do
    echo_quaacks
    described_class.new(host: "user@jump-1.example", ssh:).call("probe", args: { "v0" => "a b" }, input: {})

    expect(EnclaveCommands.ssh_argv(dir))
      .to eq(["-T", "-o", "BatchMode=yes", "--", "user@jump-1.example", "quaacks probe --v0 a\\ b"])
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

  it "treats ssh failing to connect, exit 255 with nothing on stdout, as incomplete" do
    unreachable = File.join(dir, "unreachable-ssh")
    File.write(unreachable, "#!/bin/sh\necho 'ssh: connect to host jump port 22: Connection refused' >&2\nexit 255\n")
    FileUtils.chmod(0o755, unreachable)

    expect { described_class.new(host: "jump", ssh: unreachable).call("version") }
      .to raise_error(Quaack::Driver::EnclaveError, "quaacks version failed: incomplete (exit 255)")
  end
end
