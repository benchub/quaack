# frozen_string_literal: true

require "stringio"
require "quaack/driver/enclave_error"
require "quaack/driver/progress"
require "quaack/driver/setup"

# DESIGN.md setup, as `quaack setup` and `quaack run` drive them:
# the eleven quaacks subcommands in order, each skipped once the store
# holds its output. ssh is the edge, so the transport is a fake that
# records each call.
RSpec.describe Quaack::Driver::Setup do
  let(:order) do
    %w[inventory run-server qualify schema-dump statistics volatility classify redact literals clock-anchor
       racetrack-setup]
  end
  let(:outputs) do
    %w[inventory run_server qualified_query schema_subset statistics volatility classification redacted_plan
       literal_sets clock_replacements racetrack_setup]
  end
  let(:entries) { {} }
  let(:failing) { {} }
  let(:transport) do
    f = failing
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        raise f[subcommand] if f.key?(subcommand)

        Data.define(:messages).new(messages: [])
      end
    end.new
  end
  let(:io) { StringIO.new }
  let(:progress) { Quaack::Driver::Progress.new(io:, total: 11, clock: -> { 0.0 }) }

  def run(server: {}) = described_class.run(transport:, run_id: "RUN", entries:, server:, progress:)
  def subcommands = transport.calls.map(&:first)

  it "runs the eleven setup steps in order, each with the run" do
    run

    expect(subcommands).to eq(order)
    expect(transport.calls.map { it.last[:args] }).to all(eq(run: "RUN"))
  end

  it "passes the run-server flags it's given to run-server only" do
    run(server: { "host" => "rs-1", "port" => "6432", "racetrack-db" => "rt", "arena-db" => "ar" })

    expect(transport.calls.to_h["run-server"][:args])
      .to eq(run: "RUN", "host" => "rs-1", "port" => "6432", "racetrack-db" => "rt", "arena-db" => "ar")
    expect(transport.calls.reject { it.first == "run-server" }.map { it.last[:args] }).to all(eq(run: "RUN"))
  end

  it "leaves out the flags it isn't given, so run-server falls back to run_server_command for them" do
    run(server: { "racetrack-db" => "rt" })

    expect(transport.calls.to_h["run-server"][:args]).to eq(run: "RUN", "racetrack-db" => "rt")
  end

  it "skips each step whose output the store already holds" do
    outputs.first(3).each { entries[it] = true }
    entries["literal_sets"] = true

    run

    expect(subcommands).to eq(order.drop(3) - ["literals"])
  end

  it "skips the last step, racetrack-setup, when the store holds its output" do
    entries["racetrack_setup"] = true

    run

    expect(subcommands).to eq(order - ["racetrack-setup"])
    expect(io.string.lines.last)
      .to start_with("quaack: [11/11] Already done, skipping: Setting up the racetrack")
  end

  it "warns, naming only the flags, that the run-server flags it's given go unused once run-server is done" do
    entries["run_server"] = true

    run(server: { "host" => "rs-1", "port" => "6432", "racetrack-db" => nil })

    expect(subcommands).not_to include("run-server")
    expect(io.string.lines.grep(/run-server\)$/)).to eq(
      ["quaack: [2/11] Already done, skipping: Checking the run server (run-server)\n",
       "quaack: [2/11] Ignoring --host and --port, since the run already checked its run server. " \
       "To use another run server, start a new run with `quaack start` (run-server)\n"]
    )
    expect(io.string).not_to include("rs-1", "6432")
  end

  it "doesn't warn when run-server is done and no run-server flags are given" do
    entries["run_server"] = true

    run(server: { "host" => nil })

    expect(io.string).not_to include("Ignoring")
  end

  it "says it's done only when the store holds every step's output" do
    expect(described_class.done?(outputs.to_h { [it, true] })).to be(true)
    outputs.each do |missing|
      expect(described_class.done?(outputs.to_h { [it, it != missing] })).to be(false), missing
    end
  end

  it "stops at a step that fails, raising its error" do
    error = Quaack::Driver::EnclaveError.new(subcommand: "volatility", rule: "volatile_function")
    failing["volatility"] = error

    expect { run }.to raise_error(error)
    expect(subcommands).to eq(order.take(6))
    expect(io.string.lines.last).to eq("quaack: [6/11] Failed after 0s (volatility)\n")
  end

  it "says in plain English what each step does, numbered, with each skip" do
    entries["inventory"] = true

    run

    expect(io.string.lines.grep_v(/Done in/)).to eq(
      ["quaack: [1/11] Already done, skipping: Reading production's version, settings, and extensions (inventory)\n",
       "quaack: [2/11] Checking the run server (run-server)\n",
       "quaack: [3/11] Finding the tables the query reads (qualify)\n",
       "quaack: [4/11] Dumping the schema of those tables (schema-dump)\n",
       "quaack: [5/11] Reading the planner statistics for those tables (statistics)\n",
       "quaack: [6/11] Checking the query calls no volatile functions (volatility)\n",
       "quaack: [7/11] Finding the columns that may hold personal data (classify)\n",
       "quaack: [8/11] Replacing the query's literals with placeholders (redact)\n",
       "quaack: [9/11] Choosing the literal sets to measure with (literals)\n",
       "quaack: [10/11] Pinning the query's clock to when the plan was captured (clock-anchor)\n",
       "quaack: [11/11] Setting up the racetrack, a copy of production's schema and statistics (racetrack-setup)\n"]
    )
    expect(io.string.lines.grep(/Done in/).size).to eq(10)
  end
end
