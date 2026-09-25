# frozen_string_literal: true

require "pg"
require_relative "connections"
require_relative "intake"

module Quaack
  module Enclave
    # The run server (README, step 4), which `quaacks run-server` records in
    # the run's run_server entry (see Steps::RunServer), and how later steps
    # connect to it.
    #
    #   RunServer.record(host:, port:, racetrack_db:, arena_db:)  # the entry
    #   RunServer.connect(store, :racetrack)                     # or :arena
    #
    # The entry is a Hash of host, port (an Integer), racetrack_db, and
    # arena_db. It holds no credentials. A connection takes only those from
    # the run: the user and password come from the operator's libpq setup on
    # the jump server, PGUSER and the other PG environment variables, a
    # service from ~/.pg_service.conf named by PGSERVICE, and ~/.pgpass, as
    # for production (see Inventory::Production).
    #
    # record refuses rather than guesses. Each rule names what was wrong,
    # never its value:
    #
    # - bad_run_server_host: not a hostname or an IPv4 address, in the form
    #   intake takes for the production server (Intake::SERVER). A Unix
    #   socket path or an IPv6 address is unsupported in v1.
    # - bad_run_server_port: not a whole number from 1 to 65535, written
    #   with plain digits and no leading zero.
    # - bad_run_server_database: not a plain identifier, a letter, digit, or
    #   underscore first, then those or hyphens, at most 63 characters, the
    #   length Postgres keeps. Other names are unsupported in v1.
    # - run_server_same_database: the racetrack and arena are the same
    #   database. 4b builds arena from scratch, so it can't be the
    #   racetrack.
    #
    # A connection that fails is run_server_connection_failed, with nothing
    # from libpq's message, which can name the host or the user.
    module RunServer
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      PORT = /\A[1-9][0-9]{0,4}\z/
      DATABASE = /\A[A-Za-z0-9_][A-Za-z0-9_-]{0,62}\z/
      DATABASES = { racetrack: "racetrack_db", arena: "arena_db" }.freeze

      module_function

      def record(host:, port:, racetrack_db:, arena_db:)
        raise Error, "bad_run_server_host" unless plain?(host, Intake::SERVER)
        raise Error, "bad_run_server_port" unless plain?(port, PORT) && Integer(port, 10) <= 65_535
        raise Error, "bad_run_server_database" unless [racetrack_db, arena_db].all? { plain?(it, DATABASE) }
        raise Error, "run_server_same_database" if racetrack_db == arena_db

        { "host" => host, "port" => Integer(port, 10), "racetrack_db" => racetrack_db, "arena_db" => arena_db }
      end

      # A connection to the run's racetrack or arena database, its notices
      # dropped (see Connections).
      def connect(store, database) = connect_to(store.read("run_server"), database)

      # The same, for a run server entry that isn't stored yet.
      def connect_to(entry, database)
        dbname = entry.fetch(DATABASES.fetch(database))
        Connections.register(PG.connect(host: entry.fetch("host"), port: entry.fetch("port"), dbname:))
      rescue PG::Error
        raise Error, "run_server_connection_failed", cause: nil
      end

      def plain?(value, pattern) = value.is_a?(String) && value.ascii_only? && pattern.match?(value)
    end
  end
end
