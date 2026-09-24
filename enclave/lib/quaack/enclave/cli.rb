# frozen_string_literal: true

require_relative "egress"
require_relative "error_filter"
require_relative "steps/version"

module Quaack
  module Enclave
    # The quaacks command line (README, "Where QUAACK runs"). The driver
    # calls it over ssh as `quaacks <subcommand> [options]`. Each call runs
    # one step and ends: nothing stays in memory between calls.
    #
    # Stdout is the channel back to the driver, and everything on it goes
    # through the egress function, one JSON line per message, errors
    # included. Stderr goes over ssh too, so main silences it.
    class CLI
      # Each subcommand and the step it runs. To add a step, require its
      # file above and add one line here.
      STEPS = {
        "version" => Steps::Version
      }.freeze

      # Other names for a subcommand.
      ALIASES = { "--version" => "version" }.freeze

      # The step name error lines carry when argv names no step.
      CLI_STEP = "cli"

      Refused = Class.new(StandardError) do
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super("refused: #{rule}")
        end
      end

      EX_OK = 0
      # sysexits.h's EX_USAGE.
      EX_USAGE = 64

      # What the exe runs. It silences stderr, takes stdout for egress, and
      # runs argv.
      def self.main(argv, steps: STEPS)
        ErrorFilter.silence_stderr!
        new(steps:, out: claim_stdout!).run(argv)
      end

      # Points file descriptor 1 at the null device for the rest of the
      # process and returns a copy of the real stdout, which only the CLI
      # writes to.
      def self.claim_stdout!
        out = STDOUT.dup # rubocop:disable Style/GlobalStdStream
        STDOUT.reopen(File::NULL, "w") # rubocop:disable Style/GlobalStdStream
        $stdout = STDOUT # rubocop:disable Style/GlobalStdStream
        out.sync = true
        out
      end

      def initialize(steps: STEPS, out: $stdout)
        @steps = steps
        @out = out
      end

      # Runs argv and returns the exit status.
      def run(argv)
        name = ALIASES.fetch(argv.first, argv.first)
        step = @steps[name]
        step_name = step ? name : CLI_STEP
        ErrorFilter.guard(step: step_name, out: @out) do
          raise Refused, "usage" unless step && argv.size == 1

          write(step.call.filter_map { Egress.serialize(it) }.map { "#{it}\n" }.join)
          EX_OK
        rescue Refused => e
          write("#{ErrorFilter.to_egress(e, step: step_name)}\n")
          EX_USAGE
        end
      end

      private

      def write(text)
        @out.write(text)
        @out.flush
      end
    end
  end
end
