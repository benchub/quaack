# frozen_string_literal: true

require_relative "../intake"

module Quaack
  module Enclave
    module Steps
      # `quaacks intake --query <file> --plan <file> --server <name>
      # [--port <n>] [--database <name>] [--captured-at <time>]` (DESIGN.md's input). The operator runs it on the
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
      # clock_anchor (see Intake.clock_anchor). With --port it gets a fifth,
      # production_port, an Integer, which every production connection
      # passes along with the server (Inventory::Production.params). Without
      # it there's no such entry, and libpq's setup picks the port. With
      # --database it gets production_database, a String, which every
      # production connection passes as dbname, pg_dump's included; without
      # it libpq's setup picks the database, as before. The query and the plan hold
      # production literals, so only the run ID goes out. The run ID is
      # shape-class data: the time the run started and eight random hex
      # characters (Store::RUN_ID). The paths, the server name, and the port
      # are the operator's own, and never go out either.
      module Intake
        OPTIONS = { "query" => :value, "plan" => :value, "server" => :value, "port" => :value, "database" => :value,
                    "captured-at" => :value }.freeze
        REQUIRED = %w[query plan server].freeze

        module_function

        def call(store:, options:, **)
          entries(options).each { |name, value| store.write(name, value) }
          [{ type: :run, run_id: store.run_id }]
        end

        # Each entry the run gets, checked, in the order the checks run. The
        # plan comes last, since its entry marks a finished intake for
        # Store.sweep (Store::FINISHED_ENTRY), and every check runs before
        # call writes anything.
        def entries(options)
          database = options["database"]
          {
            "server" => Enclave::Intake.server(options["server"]),
            **(options.key?("port") ? { "production_port" => Enclave::Intake.port(options["port"]) } : {}),
            **(database ? { "production_database" => Enclave::Intake.production_database(database) } : {}),
            "clock_anchor" => Enclave::Intake.clock_anchor(options["captured-at"]),
            "query" => Enclave::Intake.query(options["query"]),
            "plan" => Enclave::Intake.plan(options["plan"])
          }
        end
      end
    end
  end
end
