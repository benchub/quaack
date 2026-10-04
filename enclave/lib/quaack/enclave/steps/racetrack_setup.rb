# frozen_string_literal: true

require_relative "../racetrack"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks racetrack-setup --run <run ID>` (DESIGN.md's racetrack-setup): sets up the
      # racetrack database recorded by `quaacks run-server` (see Racetrack),
      # using the run's clock_anchor entry.
      #
      # It refuses a run with no run_server entry
      # (racetrack_setup_no_run_server) before connecting. Then it connects
      # with RunServer.connect and runs Racetrack.setup. Only when setup
      # succeeds does it write racetrack_setup, the marker true, for later
      # racetrack steps to require.
      #
      # The racetrack is a restore of production, so nothing read from it
      # goes out. Its only line is DONE, and a failure names only its rule.
      module RacetrackSetup
        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        module_function

        def call(store:, **)
          raise Error, "racetrack_setup_no_run_server" unless store.entry?("run_server")

          connection = Enclave::RunServer.connect(store, :racetrack)
          Racetrack.setup(store:, connection:)
          store.write("racetrack_setup", true)
          []
        ensure
          connection&.close
        end
      end
    end
  end
end
