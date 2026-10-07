# frozen_string_literal: true

require_relative "../arena"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks arena-setup --run <run ID>` (DESIGN.md's arena-setup): builds the arena
      # database recorded by `quaacks run-server` (see Arena), beside the
      # racetrack, from the run's inventory, full schema dump, and
      # clock_anchor.
      #
      # It refuses a run with no run_server entry (arena_setup_no_run_server)
      # before connecting. It connects to the racetrack to create arena,
      # then to arena. Only when everything succeeds does it write
      # arena_setup, the marker true, for later arena steps to require.
      #
      # It sends one step_counts: tables, how many tables arena holds (see
      # Arena.build). Then DONE. A failure names only its rule.
      module ArenaSetup
        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        module_function

        def call(store:, **)
          raise Error, "arena_setup_no_run_server" unless store.entry?("run_server")

          racetrack = Enclave::RunServer.connect(store, :racetrack)
          tables = Arena.build(store:, racetrack:, name: store.read("run_server").fetch("arena_db"),
                               connect: -> { Enclave::RunServer.connect(store, :arena) })
          store.write("arena_setup", true)
          [{ type: :step_counts, tables: }]
        ensure
          racetrack&.close
        end
      end
    end
  end
end
