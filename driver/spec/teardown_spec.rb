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
                                  "Run this on the jump server: quaacks teardown --run #{run_id}\n")
    end
  end

  context "when the enclave ends without a teardown line" do
    let(:transport) { Quaack::Driver::Transport::Local.new(command: EnclaveCommands.raw(%(print %({"type":"done"}\n)))) }

    it "fails the run as no_teardown" do
      expect { around_run }.to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("no_teardown") }
      expect(stderr.string).to include("(no_teardown). Run this on the jump server")
    end
  end

  # Task 20260927-25: a transport at the edge that fails in a way the real
  # ones don't, or that gets a signal while teardown runs.
  context "with a transport that raises something other than an EnclaveError" do
    let(:transport) { Class.new { def call(*, **) = raise(IOError, "sentinel-io-7f3a") }.new }
    let(:driver_error) do
      "quaack: couldn't tear down run #{run_id} (driver_error). " \
        "Run this on the jump server: quaacks teardown --run #{run_id}\n"
    end

    it "never masks the run's own error, and tells the operator how to finish teardown" do
      expect { around_run { raise ArgumentError, "boom" } }.to raise_error(ArgumentError, "boom")
      expect(stderr.string).to eq(driver_error)
    end

    it "fails an otherwise good run with that error" do
      expect { around_run }.to raise_error(IOError, "sentinel-io-7f3a")
      expect(stderr.string).to eq(driver_error)
    end
  end

  context "when a signal interrupts teardown" do
    let(:transport) { Class.new { def call(*, **) = Process.kill("TERM", Process.pid) && sleep(5) }.new }
    let(:finish) { "Run this on the jump server: quaacks teardown --run #{run_id}\n" }

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
                              "Run this on the jump server: quaacks teardown --run #{run_id}\n")
  end

  it "skips teardown with keep, and prints the run ID and the command to run later" do
    expect(around_run(keep: true)).to eq(:result)
    expect(File.exist?(store)).to be(true)
    expect(stderr.string).to eq("quaack: kept run #{run_id}. To tear it down later, run this on the jump server: " \
                                "quaacks teardown --run #{run_id}\n")
  end

  it "keeps the run with keep even when the run raises" do
    expect { around_run(keep: true) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
    expect(File.exist?(store)).to be(true)
    expect(stderr.string).to include("quaacks teardown --run #{run_id}")
  end
end
