# frozen_string_literal: true

require_relative "../run_server"
require_relative "../run_server_check"

module Quaack
  module Enclave
    module Steps
      # `quaacks run-server --run <run ID> --host <host> --port <port>
      # --racetrack-db <name> --arena-db <name>` (README, step 4): checks the
      # run server the operator built against the run's step 2 inventory,
      # and records it in the run's run_server entry (see RunServer), for
      # later steps to connect with (RunServer.connect).
      #
      # It checks the arguments first, then that the run has an inventory
      # (run_server_no_inventory), both before any connection. Then it
      # connects to the racetrack database with the operator's libpq setup
      # and runs RunServerCheck there. It checks only the racetrack: 4b
      # makes arena, from template0, so arena needn't exist yet. The quiet
      # checks see every database on the server, arena's included, and the
      # rest are what 4a and step 5 depend on. Anything that fails writes
      # nothing, so a recorded run server is one that passed.
      #
      # Its only line is DONE. The host, the port, and the database names
      # are the operator's own configuration, so none of them goes out, and
      # a failed check names only its rule.
      module RunServer
        OPTIONS = { "host" => :value, "port" => :value, "racetrack-db" => :value, "arena-db" => :value }.freeze
        REQUIRED = OPTIONS.keys.freeze

        module_function

        def call(store:, options:, **)
          entry = Enclave::RunServer.record(host: options["host"], port: options["port"],
                                            racetrack_db: options["racetrack-db"], arena_db: options["arena-db"])
          raise Enclave::RunServer::Error, "run_server_no_inventory" unless store.entry?("inventory")

          check(store, entry)
          store.write("run_server", entry)
          []
        end

        def check(store, entry)
          connection = Enclave::RunServer.connect_to(entry, :racetrack)
          RunServerCheck.run(store:, connection:)
        ensure
          connection&.close
        end
      end
    end
  end
end
