# frozen_string_literal: true

require_relative "../intake"

module Quaack
  module Enclave
    module Steps
      # `quaacks intake --query <file> --plan <file> --server <name>
      # [--captured-at <time>]` (DESIGN.md's input). The operator runs it on the
      # jump server, where the query and its EXPLAIN (ANALYZE, BUFFERS,
      # SETTINGS, FORMAT JSON) output already sit in files. It checks the
      # three inputs (see Intake), starts the run that holds them, and
      # prints the run's ID for the driver to use.
      #
      # The CLI checks the arguments, including the REQUIRED options, then
      # starts the run before the step, and deletes it again if the step
      # fails (new_run: true), so a refused input leaves nothing behind.
      #
      # The run gets four entries: query (its text, without a leading byte
      # order mark), plan (the parsed EXPLAIN output), server, and
      # clock_anchor (see Intake.clock_anchor). The query and the plan hold
      # production literals, so only the run ID goes out. The run ID is
      # shape-class data: the time the run started and eight random hex
      # characters (Store::RUN_ID). The paths and the server name are the
      # operator's own, and never go out either.
      module Intake
        OPTIONS = { "query" => :value, "plan" => :value, "server" => :value, "captured-at" => :value }.freeze
        REQUIRED = %w[query plan server].freeze

        module_function

        def call(store:, options:, **)
          entries(options).each { |name, value| store.write(name, value) }
          [{ type: :run, run_id: store.run_id }]
        end

        # Each entry the run gets, checked, in the order the checks run.
        def entries(options)
          {
            "server" => Enclave::Intake.server(options["server"]),
            "clock_anchor" => Enclave::Intake.clock_anchor(options["captured-at"]),
            "query" => Enclave::Intake.query(options["query"]),
            "plan" => Enclave::Intake.plan(options["plan"])
          }
        end
      end
    end
  end
end
