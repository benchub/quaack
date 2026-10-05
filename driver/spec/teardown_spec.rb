# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/teardown"
require "quaack/driver/transport/local"

# Task 20260927-23: Teardown.around runs the real `quaacks teardown` through
# Transport::Local when a run ends, however it ends. HOME points the child
# at a throwaway store.
RSpec.describe Quaack::Driver::Teardown do
  let(:home) { Dir.mktmpdir("quaack-teardown") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:store) { File.join(home, ".quaack", "runs", run_id) }
  let(:stderr) { StringIO.new }
  let(:transport) { Quaack::Driver::Transport::Local.new(command: EnclaveCommands.quaacks) }
  let(:gone_hint) { "Destroy the run server for run #{run_id} now." }

  around do |example|
    old = Dir.home
    ENV["HOME"] = home
    example.run
  ensure
    ENV["HOME"] = old
    FileUtils.rm_rf(home)
  end

  before do
    FileUtils.mkdir_p(store)
    FileUtils.chmod_R(0o700, File.join(home, ".quaack"))
  end

  def around_run(keep: false, &block)
    described_class.around(transport:, run_id:, stderr:, keep:, &block || -> { :result })
  end

  it "deletes the store after a run that succeeds, returns the block's value, and says to destroy the server" do
    expect(around_run).to eq(:result)
    expect(File.exist?(store)).to be(false)
    expect(stderr.string).to eq("quaack: deleted the store for run #{run_id}. #{gone_hint}\n")
  end

  it "deletes the store after a run that raises, and re-raises the run's error" do
    expect { around_run { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
    expect(File.exist?(store)).to be(false)
  end

  it "deletes the store when the run gets SIGTERM, and lets the signal through" do
    expect { around_run { Process.kill("TERM", Process.pid) && sleep(5) } }.to raise_error(SignalException)
    expect(File.exist?(store)).to be(false)
  end

  it "says nothing's left when the enclave's destroy_command destroyed the run server" do
    File.write(File.join(home, ".quaack", "config.json"), '{"destroy_command": "true"}')
    expect(around_run).to eq(:result)
    expect(stderr.string).to eq("quaack: deleted the store for run #{run_id}, and destroyed its run server.\n")
  end

  # Task 20261004-60: the run's server entry can't be read, so the
  # enclave's destroy_command never runs, and the run server may be up.
  it "says to destroy the run server by hand when the enclave couldn't read the run's server" do
    File.write(File.join(home, ".quaack", "config.json"), '{"destroy_command": "true"}')
    File.write(File.join(store, "server.json"), "not json")

    expect { around_run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("destroy_command_not_run") }
    expect(stderr.string).to eq("quaack: couldn't tear down run #{run_id} (destroy_command_not_run). destroy_command " \
                                "didn't run, so destroy the run server for run #{run_id} yourself. Then check or " \
                                "remove ~/.quaack/runs/#{run_id} on the jump server by hand.\n")
    expect(File.directory?(store)).to be(true)
  end

  # Task 20261004-60: failure's words for an error that isn't an
  # EnclaveError, once only teardown is left, name only driver_error.
  describe ".failure" do
    let(:teardown) { described_class.new(transport, run_id, stderr) }
    let(:transport) { Class.new { def call(*, **) = raise(IOError, "sentinel-io-7f3a") }.new }

    it "names driver_error and points to teardown's line for a non-EnclaveError teardown failure" do
      error = begin
        teardown.finish(nil)
      rescue described_class::DriverError => e
        e
      end

      expect(described_class.failure(error, teardown, run_id))
        .to eq("driver_error. To go on, #{described_class::TEARDOWN_LEFT}")
    end

    it "keeps the message of the run's own non-EnclaveError" do
      expect(described_class.failure(IOError.new("llm said no"), teardown, run_id)).to eq("llm said no")
    end
  end

  it "treats a store that's already gone as torn down" do
    FileUtils.rm_rf(store)
    expect(around_run).to eq(:result)
    expect(stderr.string).to eq("quaack: deleted the store for run #{run_id}. #{gone_hint}\n")
  end

  context "when the enclave can't tear the run down" do
    before do
      FileUtils.rm_rf(store)
      File.write(store, "not a run")
    end

    let(:by_hand) do
      "quaack: couldn't tear down run #{run_id} (bad_run). " \
        "Check or remove ~/.quaack/runs/#{run_id} on the jump server by hand.\n"
    end

    it "fails an otherwise good run with the rule and tells the operator what to remove" do
      expect { around_run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("bad_run") }
      expect(stderr.string).to eq(by_hand)
    end

    it "never masks the run's own error" do
      expect { around_run { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
      expect(stderr.string).to eq(by_hand)
    end
  end

  context "when the call to the enclave fails" do
    let(:transport) { Quaack::Driver::Transport::Local.new(command: EnclaveCommands.raw("exit 3")) }

    it "tells the operator to run teardown on the jump server" do
      expect { around_run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("incomplete") }
      expect(stderr.string).to eq("quaack: couldn't tear down run #{run_id} (incomplete). " \
                                  "To tear it down later, run this on the jump server: " \
                                  "quaacks teardown --run #{run_id}\n")
    end
  end

  context "when the enclave ends without a teardown line" do
    let(:transport) { Quaack::Driver::Transport::Local.new(command: EnclaveCommands.raw(%(print %({"type":"done"}\n)))) }

    it "fails the run as no_teardown" do
      expect { around_run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("no_teardown") }
      expect(stderr.string).to include("(no_teardown). To tear it down later, run this on the jump server")
    end
  end

  # Task 20260927-25: a transport at the edge that fails in a way the real
  # ones don't, or that gets a signal while teardown runs.
  context "with a transport that raises something other than an EnclaveError" do
    let(:transport) { Class.new { def call(*, **) = raise(IOError, "sentinel-io-7f3a") }.new }
    let(:driver_error) do
      "quaack: couldn't tear down run #{run_id} (driver_error). " \
        "To tear it down later, run this on the jump server: quaacks teardown --run #{run_id}\n"
    end

    it "never masks the run's own error, and tells the operator how to finish teardown" do
      expect { around_run { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
      expect(stderr.string).to eq(driver_error)
    end

    # Task 20261004-60: as a DriverError naming only its rule, so quaack
    # run reports it like the enclave's rules.
    it "fails an otherwise good run with a DriverError, whose cause is that error" do
      expect { around_run }.to raise_error(described_class::DriverError, "driver_error") { |e|
        expect([e.cause.class, e.cause.message]).to eq([IOError, "sentinel-io-7f3a"])
      }
      expect(stderr.string).to eq(driver_error)
    end
  end

  # Task 20260930-1: an error outside StandardError, such as a LoadError.
  context "with a transport that raises an error that isn't a StandardError" do
    let(:transport) { Class.new { def call(*, **) = raise(LoadError, "sentinel-load-9b2d") }.new }
    let(:driver_error) do
      "quaack: couldn't tear down run #{run_id} (driver_error). " \
        "To tear it down later, run this on the jump server: quaacks teardown --run #{run_id}\n"
    end

    it "never masks the run's own error, and tells the operator how to finish teardown" do
      expect { around_run { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
      expect(stderr.string).to eq(driver_error)
    end

    it "fails an otherwise good run with a DriverError, and tells the operator how to finish teardown" do
      expect { around_run }.to raise_error(described_class::DriverError, "driver_error") { |e|
        expect([e.cause.class, e.cause.message]).to eq([LoadError, "sentinel-load-9b2d"])
      }
      expect(stderr.string).to eq(driver_error)
    end
  end

  context "when a signal interrupts teardown" do
    let(:transport) { Class.new { def call(*, **) = Process.kill("TERM", Process.pid) && sleep(5) }.new }
    # Task 20261004-29: worded like the other teardown hints.
    let(:finish) { "To tear it down later, run this on the jump server: quaacks teardown --run #{run_id}\n" }

    it "lets the signal through, and first prints the run's own error and how to finish teardown" do
      expect { around_run { raise ArgumentError, "boom" } }.to raise_error(SignalException, "SIGTERM")
      expect(stderr.string).to eq("quaack: run #{run_id} failed (ArgumentError: boom), " \
                                  "and a signal interrupted its teardown. #{finish}")
    end

    it "names only the rule of a run that failed with an EnclaveError" do
      run_error = Quaack::Driver::EnclaveError.new(subcommand: "explain", rule: "timeout", step: "explain")
      expect { around_run { raise run_error } }.to raise_error(SignalException, "SIGTERM")
      expect(stderr.string).to eq("quaack: run #{run_id} failed (timeout), " \
                                  "and a signal interrupted its teardown. #{finish}")
    end

    it "says only how to finish teardown after a run that succeeded" do
      expect { around_run }.to raise_error(SignalException, "SIGTERM")
      expect(stderr.string).to eq("quaack: a signal interrupted the teardown of run #{run_id}. #{finish}")
    end

    # Task 20260930-1: an error the caller is handling isn't the run's.
    it "reports no run error for a run that succeeded, even when called while handling another error" do
      begin
        raise ArgumentError, "sentinel-outer-5c1e"
      rescue ArgumentError
        expect { around_run }.to raise_error(SignalException, "SIGTERM")
      end
      expect(stderr.string).to eq("quaack: a signal interrupted the teardown of run #{run_id}. #{finish}")
    end
  end

  # A second Ctrl-C, in a child process with Ruby's own INT handler (RSpec
  # traps INT in this one).
  it "still stops the process on a second Ctrl-C during teardown, after printing the run's own error" do
    source = <<~RUBY
      require "quaack/driver/teardown"
      transport = Class.new { def call(*, **) = Process.kill("INT", Process.pid) && sleep(5) }.new
      Quaack::Driver::Teardown.around(transport:, run_id: ARGV[0], stderr: $stderr) { raise ArgumentError, "boom" }
      puts "still running"
    RUBY
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", source, run_id)
    expect([out, status.termsig]).to eq(["", Signal.list.fetch("INT")])
    expect(err).to start_with("quaack: run #{run_id} failed (ArgumentError: boom), " \
                              "and a signal interrupted its teardown. " \
                              "To tear it down later, run this on the jump server: quaacks teardown --run #{run_id}\n")
  end

  it "skips teardown with keep, and prints the run ID and the command to run later" do
    expect(around_run(keep: true)).to eq(:result)
    expect(File.exist?(store)).to be(true)
    expect(stderr.string).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                                "quaacks teardown --run #{run_id}\n")
  end

  # Task 20261004-26: once ssh is known to be down, teardown's own call
  # would only fail too, after another connect timeout and probe.
  context "after a run that failed as ssh_failed" do
    let(:ssh_failed) { Quaack::Driver::EnclaveError.new(subcommand: "explain", rule: "ssh_failed", exit_status: 255) }

    it "skips teardown without calling the jump server, re-raises, and prints the command to run later" do
      expect { around_run { raise ssh_failed } }.to raise_error(ssh_failed)
      expect(File.exist?(store)).to be(true)
      expect(stderr.string).to eq("quaack: skipped the teardown of run #{run_id}, since ssh to the jump server " \
                                  "failed. To tear it down later, run this on the jump server: " \
                                  "quaacks teardown --run #{run_id}\n")
    end

    it "still tears down after a run that failed with another rule" do
      other = Quaack::Driver::EnclaveError.new(subcommand: "explain", rule: "incomplete", exit_status: 255)
      expect { around_run { raise other } }.to raise_error(other)
      expect(File.exist?(store)).to be(false)
    end
  end

  # Task 20261004-26: the caller says "resume" only when the store is left.
  describe "#deleted?" do
    let(:teardown) { described_class.new(transport, run_id, stderr) }

    it "is true once teardown deleted the store" do
      teardown.around(keep: false) { :result }
      expect(teardown.deleted?).to be(true)
    end

    it "is false with keep, after a skipped teardown, and before teardown runs" do
      expect(teardown.deleted?).to be(false)
      teardown.around(keep: true) { :result }
      expect(teardown.deleted?).to be(false)
      ssh_failed = Quaack::Driver::EnclaveError.new(subcommand: "explain", rule: "ssh_failed")
      expect { teardown.around(keep: false) { raise ssh_failed } }.to raise_error(ssh_failed)
      expect([teardown.deleted?, File.exist?(store)]).to eq([false, true])
    end

    it "is false when teardown failed" do
      FileUtils.rm_rf(store)
      File.write(store, "not a run")
      expect { teardown.around(keep: false) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
      expect(teardown.deleted?).to be(false)
    end
  end

  it "keeps the run with keep even when the run raises" do
    expect { around_run(keep: true) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
    expect(File.exist?(store)).to be(true)
    expect(stderr.string).to include("quaacks teardown --run #{run_id}")
  end
end
