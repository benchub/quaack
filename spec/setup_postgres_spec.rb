# frozen_string_literal: true

require_relative "spec_helper"
require "stringio"
require "quaack/driver/progress"
require "quaack/driver/setup"

# Task 20260928-1: quaack setup's steps, Driver::Setup, through the real
# quaacks on a throwaway Postgres. Its resume rests on what `quaacks status`
# says the store holds after each step.
module SetupPostgresSpec
  # The Local transport to quaacks, recording each subcommand called. Given
  # fail_at, it raises for that subcommand instead, as a dropped ssh
  # connection would, without calling quaacks.
  class Recording
    attr_reader :calls

    def initialize(fail_at: nil)
      @transport = Quaack::Driver::Transport::Local.new(command: PromptPack::QUAACKS)
      @fail_at = fail_at
      @calls = []
    end

    def call(subcommand, args: {})
      @calls << subcommand
      raise Quaack::Driver::EnclaveError.new(subcommand:, rule: "transport_failed") if subcommand == @fail_at

      @transport.call(subcommand, args:)
    end
  end
end

RSpec.describe Quaack::Driver::Setup do
  def recording(fail_at: nil) = SetupPostgresSpec::Recording.new(fail_at:)

  let(:server) { TestPostgres.server }
  let(:query) { PromptPack::QUERIES.first }
  let(:steps) { described_class::STEPS.map(&:subcommand) }

  def flags(racetrack)
    { "host" => server.host, "port" => server.port.to_s, "racetrack-db" => racetrack,
      "arena-db" => "#{racetrack}_arena" }
  end

  def set_up(transport, run_id, racetrack, progress: Quaack::Driver::Progress::NULL)
    described_class.run(transport:, run_id:, entries: Quaack::Driver::Pipeline.status(transport, run_id),
                        server: flags(racetrack), progress:)
  end

  # Starts a run for query, then yields the transport and the run ID.
  def with_run
    Dir.mktmpdir("quaack-setup") do |home|
      prod, racetrack = PromptPack.databases(server, query)
      PromptPack.with_env(home, server, prod) do
        local = Quaack::Driver::Transport::Local.new(command: PromptPack::QUAACKS)
        yield PromptPack.intake(local, home, server, query, prod), racetrack
      end
    ensure
      PipelineReplay.drop(server, [prod, racetrack, "#{racetrack}_arena"].compact)
    end
  end

  it "does setup in order, so the store holds each one's output, and a rerun calls none of them" do
    with_run do |run_id, racetrack|
      first = recording
      set_up(first, run_id, racetrack)
      again = recording
      stderr = StringIO.new
      set_up(again, run_id, racetrack, progress: Quaack::Driver::Progress.new(io: stderr, total: 11))

      expect(first.calls).to eq(["status"] + steps)
      expect(Quaack::Driver::Pipeline.status(again, run_id).slice(*described_class::STEPS.map(&:output)).values)
        .to eq([true] * 11)
      expect(again.calls).to eq(%w[status status])
      expect(stderr.string.lines.grep(/Already done, skipping/).size).to eq(11)
    end
  end

  it "picks up where a failed setup stopped, skipping what's done" do
    with_run do |run_id, racetrack|
      expect { set_up(recording(fail_at: "schema-dump"), run_id, racetrack) }
        .to raise_error(Quaack::Driver::EnclaveError)
      resumed = recording
      set_up(resumed, run_id, racetrack)

      expect(resumed.calls).to eq(["status"] + steps.drop(steps.index("schema-dump")))
    end
  end
end
