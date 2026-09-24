# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/transport"

# The driver's side of the link to the enclave script. Most of these run the
# real enclave/exe/quaacks, or CLI.main with a test step, through the local
# transport. The rest stand in for the enclave script with a raw command, to
# print what the real one can't, such as a cut-off line.
RSpec.describe Quaack::Driver::Transport do
  let(:local) { Quaack::Driver::Transport::Local }
  let(:dir) { Dir.mktmpdir("quaack-driver-transport") }
  let(:sentinel) { "sentinel-7c31a9-ssn" }

  after { FileUtils.rm_rf(dir) }

  def probe(body, **step) = local.new(command: EnclaveCommands.probe(dir, body, **step))
  def raw(source) = local.new(command: EnclaveCommands.raw(source))

  # The EnclaveError that calling transport raises.
  def failure(transport, subcommand = "probe", **)
    transport.call(subcommand, **)
  rescue Quaack::Driver::EnclaveError => e
    e
  else
    raise "expected an EnclaveError, but the call succeeded"
  end

  describe "a run that succeeds" do
    it "returns the messages of the real quaacks version step, without the done line" do
      result = local.new(command: EnclaveCommands.quaacks).call("version")

      expect(result.messages).to eq([{ "type" => "version", "version" => EnclaveCommands.enclave_version }])
    end
  end

  describe "a run that fails" do
    # A step error with its own rule and SQLSTATE, and a message holding a
    # sentinel, which must never reach the driver.
    let(:step_error) do
      <<~RUBY
        error = RuntimeError.new("#{sentinel}")
        error.define_singleton_method(:rule) { "unique_violation" }
        error.define_singleton_method(:sqlstate) { "23505" }
        raise error
      RUBY
    end

    it "raises an EnclaveError with the error line's step, rule, and SQLSTATE, and the exit status" do
      error = failure(probe(step_error))

      expect([error.subcommand, error.step, error.rule, error.sqlstate]).to eq(%w[probe probe unique_violation 23505])
      expect([error.exit_status, error.signal]).to eq([70, nil])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([false, true, false])
      expect(error.message).to eq("quaacks probe failed: unique_violation (step probe, SQLSTATE 23505, exit 70)")
    end

    it "carries only the error line's fields, never the step's error message" do
      error = failure(probe(step_error))

      expect(error.message).not_to include(sentinel)
      expect(error.full_message(highlight: false)).not_to include(sentinel)
      expect(error.cause).to be_nil
    end

    it "treats the CLI refusing the call as usage, exit 64" do
      error = failure(local.new(command: EnclaveCommands.quaacks), "version", args: { "bogus" => "x" })

      expect([error.step, error.rule, error.sqlstate, error.exit_status]).to eq(["version", "usage", nil, 64])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([true, false, false])
      expect(error.message).to eq("quaacks version failed: usage (step version, exit 64)")
    end

    it "treats a death by a signal as killed, with the error line the enclave wrote before it died" do
      error = failure(probe('Process.kill("TERM", Process.pid); sleep 10'))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["internal_error", "probe", nil, "TERM"])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([false, false, true])
      expect(error.message).to eq("quaacks probe failed: internal_error (step probe, signal TERM)")
    end

    it "treats a death by SIGKILL, which leaves no error line, as incomplete and killed" do
      error = failure(probe('Process.kill("KILL", Process.pid); sleep 10'))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["incomplete", nil, nil, "KILL"])
      expect(error.killed?).to be(true)
      expect(error.message).to eq("quaacks probe failed: incomplete (signal KILL)")
    end

    it "treats a run that exits 0 without its done line, as after exit!(0), as incomplete" do
      error = failure(probe("exit!(0)"))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["incomplete", nil, 0, nil])
      expect(error.message).to eq("quaacks probe failed: incomplete (exit 0)")
    end

    it "discards the lines before an error line" do
      error = failure(raw(<<~'RUBY'))
        print %({"type":"version","version":"1"}\n{"type":"done"}\n{"type":"error","step":"probe","rule":"flush_failed"}\n)
        exit 70
      RUBY

      expect([error.rule, error.exit_status]).to eq(["flush_failed", 70])
    end

    it "takes the first error line when there are several" do
      error = failure(raw(<<~'RUBY'))
        print %({"type":"error","step":"probe","rule":"first"}\n{"type":"error","step":"cli","rule":"second"}\n)
        exit 70
      RUBY

      expect([error.step, error.rule]).to eq(%w[probe first])
    end

    it "treats a run that ends with its done line but exits nonzero, with no error line, as incomplete" do
      error = failure(raw(%(print %({"type":"version","version":"1"}\\n{"type":"done"}\\n); exit 3)))

      expect([error.rule, error.exit_status, error.signal]).to eq(["incomplete", 3, nil])
    end

    it "treats a run that ends with its done line but dies by a signal, with no error line, as incomplete" do
      error = failure(raw(%(print %({"type":"done"}\\n); $stdout.flush; Process.kill("KILL", Process.pid))))

      expect([error.rule, error.exit_status, error.signal]).to eq(["incomplete", nil, "KILL"])
    end
  end
end
