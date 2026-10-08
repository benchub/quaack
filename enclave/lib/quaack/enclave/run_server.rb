# frozen_string_literal: true

require "pg"
require "quaack/protocol/database_name"
require "quaack/protocol/port"
require_relative "connections"
require_relative "intake"

module Quaack
  module Enclave
    # The run server (DESIGN.md's run-server), which `quaacks run-server` records in
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
    #   with plain digits and no leading zero (Protocol::Port).
    # - bad_run_server_database: not a plain identifier, a letter, digit, or
    #   underscore first, then those or hyphens, at most 63 characters, the
    #   length Postgres keeps. Other names are unsupported in v1.
    # - run_server_same_database: the racetrack and arena are the same
    #   database. arena-setup builds arena from scratch, so it can't be the
    #   racetrack.
    #
    # An arena connection's TimeZone is set, for the session, to the one
    # production had when inventory read it (inventory's settings), so a
    # counterexample's timestamptz literal, a date cast to one, or 'today'
    # anchored to the clock means the same instant in every arena session,
    # and the one it means in production, whatever the operator's PGTZ or
    # the server's default (tasks 20260925-2 and 20261004-95). It's a SET,
    # not a connection option, since libpq sends PGTZ after the options, and
    # it wins. Arena.build's RESET ALL after the dump undoes it for the rest
    # of that build, which reads no times. The racetrack keeps its TimeZone,
    # which run-server checks against production's. A run with no inventory
    # can't connect to arena (Store's missing_inventory).
    #
    # Both connections set the session's search_path to the run's
    # search_path entry, the one qualify resolved names through, so a name
    # qualify leaves bare, such as an extension's =, resolves as it did in
    # production (DESIGN.md's qualify). A run without the entry keeps the
    # role's own path.
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

      DATABASE = Protocol::DatabaseName::PATTERN
      DATABASES = { racetrack: "racetrack_db", arena: "arena_db" }.freeze
      ARENA_TIME_ZONE_SQL = "SELECT pg_catalog.set_config('TimeZone', $1, false)"

      module_function

      def record(host:, port:, racetrack_db:, arena_db:)
        raise Error, "bad_run_server_host" unless plain?(host, Intake::SERVER)
        raise Error, "bad_run_server_port" unless Protocol::Port.valid?(port)
        raise Error, "bad_run_server_database" unless [racetrack_db, arena_db].all? { plain?(it, DATABASE) }
        raise Error, "run_server_same_database" if racetrack_db == arena_db

        { "host" => host, "port" => Integer(port, 10), "racetrack_db" => racetrack_db, "arena_db" => arena_db }
      end

      # A connection to the run's racetrack or arena database, its notices
      # dropped (see Connections).
      def connect(store, database)
        time_zone = store.read("inventory").fetch("settings").fetch("TimeZone") if database == :arena
        connect_to(store.read("run_server"), database, time_zone:).tap { search_path!(it, store) }
      end

      # The same, for a run server entry that isn't stored yet. time_zone is
      # arena's TimeZone, production's.
      def connect_to(entry, database, time_zone: nil)
        dbname = entry.fetch(DATABASES.fetch(database))
        conn = Connections.register(PG.connect(host: entry.fetch("host"), port: entry.fetch("port"), dbname:))
        conn.exec_params(ARENA_TIME_ZONE_SQL, [time_zone]) if database == :arena
        conn
      rescue PG::Error
        raise Error, "run_server_connection_failed", cause: nil
      end

      SEARCH_PATH_SQL = "SELECT pg_catalog.set_config('search_path', $1, false)"
      PLAIN_SCHEMA = /\A[a-z_][a-z0-9_$]*\z/

      # Sets the search path qualify resolved names through, if the run has
      # one.
      def search_path!(conn, store)
        return unless store.entry?("search_path")

        conn.exec_params(SEARCH_PATH_SQL, [path_text(store.read("search_path"))])
      end

      # The plan's Settings, with the run's stored search_path in place of
      # the plan's, if the run has one, for a check that resolves names on
      # the run server, such as rewrite-check's. It's the path qualify
      # resolved the original through, as the operator's role: the run
      # server connects as another role, so the plan's own path would mean
      # another "$user" there, and other schemas that role may use.
      def plan_settings(store)
        settings = store.read("plan")[0]["Settings"]
        return settings unless store.entry?("search_path")

        (settings || {}).merge("search_path" => path_text(store.read("search_path")))
      end

      # A stored search_path entry as a search_path setting's text.
      def path_text(schemas) = schemas.map { it.match?(PLAIN_SCHEMA) ? it : %("#{it.gsub('"', '""')}") }.join(", ")

      def plain?(value, pattern) = value.is_a?(String) && value.ascii_only? && pattern.match?(value)
    end
  end
end
