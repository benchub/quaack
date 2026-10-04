# frozen_string_literal: true

require_relative "progress"

module Quaack
  module Driver
    # DESIGN.md steps 2 to 4a, which `quaack setup` runs, and `quaack run`
    # runs first when the run hasn't had them:
    #
    #   Setup.run(transport:, run_id:, entries:, server: { "host" => "rs-1" }, progress:)
    #
    # It runs the eleven quaacks subcommands in STEPS' order over the
    # transport, each with only the run. server holds the run-server flags
    # given, by option name: host, port, racetrack-db, and arena-db. Only
    # run-server gets them, and only those given, so `quaacks run-server`
    # takes the rest from its run_server_command.
    #
    # It resumes. entries are what `quaacks status` says the store holds
    # (Pipeline.status), and a step whose output is there is skipped. Each
    # step's output is the entry it stores last, so one that's there means
    # the step finished. An EnclaveError stops it where it is.
    module Setup
      Step = Data.define(:subcommand, :id, :output, :say)

      STEPS = [
        Step.new("inventory", "2", "inventory", "Reading production's version, settings, and extensions"),
        Step.new("run-server", "4", "run_server", "Checking the run server"),
        Step.new("qualify", "3a", "qualified_query", "Finding the tables the query reads"),
        Step.new("schema-dump", "3b", "schema_subset", "Dumping the schema of those tables"),
        Step.new("statistics", "3c", "statistics", "Reading the planner statistics for those tables"),
        Step.new("volatility", "3d", "volatility", "Checking the query calls no volatile functions"),
        Step.new("classify", "3f", "classification", "Finding the columns that may hold personal data"),
        Step.new("redact", "3g", "redacted_plan", "Replacing the query's literals with placeholders"),
        Step.new("literals", "3e", "literal_sets", "Choosing the literal sets to measure with"),
        Step.new("anchor", "3h", "clock_replacements", "Pinning the query's clock to when the plan was captured"),
        Step.new("racetrack-setup", "4a", "racetrack_setup",
                 "Setting up the racetrack, a copy of production's schema and statistics")
      ].freeze
      # The run-server flags, by option name.
      SERVER_OPTIONS = %w[host port racetrack-db arena-db].freeze

      module_function

      # Whether entries say every step has run.
      def done?(entries) = STEPS.all? { entries[it.output] }

      def run(transport:, run_id:, entries:, server: {}, progress: Progress::NULL)
        STEPS.each do |step|
          next progress.skip(step.id, step.say) if entries[step.output]

          args = { run: run_id }
          args.merge!(server.slice(*SERVER_OPTIONS).compact) if step.subcommand == "run-server"
          progress.step(step.id, step.say) { transport.call(step.subcommand, args:) }
        end
      end
    end
  end
end
