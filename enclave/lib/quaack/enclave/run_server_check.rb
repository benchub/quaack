# frozen_string_literal: true

require "json"
require_relative "inventory/production"

module Quaack
  module Enclave
    # Step 4's run server checks (DESIGN.md, step 4): does the run server match
    # production's inventory (see Inventory), and is QUAACK alone on it?
    #
    #   RunServerCheck.run(store:, connection:)  # nil, or raises an Error
    #
    # connection is a superuser's connection to the racetrack database.
    # Nothing connects to the run server yet, so the caller passes it in.
    # own_connections are QUAACK's other connections to the server, such as
    # arena's, which aren't other clients.
    #
    # The checks run in this order, and the first that fails raises an
    # Error, whose rule names it:
    #
    # 1. run_server_not_superuser: the role isn't a superuser. It goes
    #    first, since only a superuser sees every other client.
    # 2. run_server_major_version: the major version isn't production's.
    # 3. run_server_extension_missing and run_server_extension_version: an
    #    extension production has isn't installed, or is at another version.
    # 4. run_server_hypopg_missing: HypoPG is neither installed nor
    #    available. 4a creates it, so available is enough.
    # 5. run_server_locale_mismatch: pg_database's datcollate, datctype,
    #    datlocprovider, datlocale, or datcollversion, or
    #    default_text_search_config, isn't production's. The database's
    #    name can differ.
    # 6. run_server_guc_mismatch: a planner setting isn't production's (see
    #    PLANNER_SQL and planner_settings).
    # 7. run_server_other_clients: pg_stat_activity shows another client
    #    backend.
    # 8. run_server_cron_elsewhere and run_server_cron_active: pg_cron runs
    #    its jobs from another database, whose cron.job this connection
    #    can't read, or cron.job here has an active job.
    # 9. run_server_autovacuum_on: autovacuum is on. With it off, a table's
    #    autovacuum_enabled can't turn it back on, so reloptions aren't read.
    #
    # An Error's message is its rule and the name of what failed, such as
    # "run_server_guc_mismatch: search_path", and never a value: settings,
    # locale names, and the database's name are production configuration.
    # ErrorFilter sends only the rule. Nothing is stored. The one exception
    # is run_server_other_clients, whose Error also carries clients: each
    # other client's pid and UTC start time, oldest first, at most
    # MAX_CLIENTS, and none if none is left to name. ErrorFilter sends those
    # too, so the operator can find and stop them. No other pg_stat_activity
    # column is read.
    #
    # Not checked, so unsupported in v1: per-tablespace random_page_cost
    # and seq_page_cost, which the inventory doesn't record, and schedulers
    # outside Postgres, which are the operator's to stop.
    module RunServerCheck
      class Error < StandardError
        attr_reader :rule, :clients

        def initialize(rule, name, clients: nil)
          @rule = rule
          @clients = clients
          super("#{rule}: #{name}")
        end
      end

      LOCALE_FIELDS = %w[datcollate datctype datlocprovider datlocale datcollversion].freeze

      # Every setting that changes plans: the ones EXPLAIN's SETTINGS would
      # list (the EXPLAIN flag), every Query Tuning setting, and three that
      # change how a quoted literal is read. unlisted_ok says whether its
      # value fits a plan whose SETTINGS doesn't list it: SETTINGS would
      # list it (the flag), and it's at its built-in default.
      PLANNER_SQL = <<~SQL
        SELECT name, 'EXPLAIN' = ANY(pg_settings_get_flags(name))
                     AND setting IS NOT DISTINCT FROM boot_val AS unlisted_ok
        FROM pg_settings
        WHERE 'EXPLAIN' = ANY(pg_settings_get_flags(name)) OR category LIKE 'Query Tuning%'
           OR name IN ('TimeZone', 'DateStyle', 'IntervalStyle')
      SQL
      CLIENTS_SQL = "SELECT count(*) FROM pg_stat_activity " \
                    "WHERE backend_type = 'client backend' AND pid <> ALL($1::int[])"
      # The other clients, for the operator to find: only each one's pid and
      # the UTC time it started, oldest first, at most MAX_CLIENTS. Nothing
      # else about a client is read.
      MAX_CLIENTS = 20
      # A client's start time, in UTC, whatever the session's TimeZone.
      BACKEND_START_SQL = %(to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
      OTHER_CLIENTS_SQL = <<~SQL.freeze
        SELECT pid, #{BACKEND_START_SQL}
        FROM pg_stat_activity
        WHERE backend_type = 'client backend' AND pid <> ALL($1::int[]) AND backend_start IS NOT NULL
        ORDER BY backend_start, pid
        LIMIT #{MAX_CLIENTS}
      SQL
      HYPOPG_SQL = "SELECT 1 FROM pg_available_extensions WHERE name = 'hypopg'"
      CRON_ACTIVE_SQL = "SELECT count(*) FROM cron.job WHERE active"

      module_function

      def run(store:, connection:, own_connections: [])
        inventory = store.read("inventory")
        own_pids = [connection, *own_connections].map { server_pid(it) }
        check_access(connection)
        check_version(connection, inventory)
        check_extensions(connection, inventory)
        check_locale(connection, inventory)
        check_planner_settings(connection, inventory)
        check_quiet(connection, own_pids)
        nil
      end

      # The pid of the server backend running this connection's queries,
      # which pg_stat_activity lists. libpq's backend_pid is the one the
      # server sent at connect time, and behind a pooler such as PgBouncer
      # it's one the pooler made up.
      def server_pid(connection) = Integer(value(connection, "SELECT pg_backend_pid()"), 10)

      def check_access(connection)
        fail!("run_server_not_superuser", "is_superuser") unless show(connection, "is_superuser") == "on"
      end

      def check_version(connection, inventory)
        major = Integer(show(connection, "server_version_num"), 10) / 10_000
        fail!("run_server_major_version", "server_version_num") unless major == inventory.fetch("major_version")
      end

      def check_extensions(connection, inventory)
        installed = connection.exec(Inventory::Production::EXTENSIONS_SQL).values.to_h
        inventory.fetch("extensions").each do |name, version|
          fail!("run_server_extension_missing", name) unless installed.key?(name)
          fail!("run_server_extension_version", name) unless installed[name] == version
        end
        # An installed extension is available too.
        fail!("run_server_hypopg_missing", "hypopg") unless value(connection, HYPOPG_SQL)
      end

      def check_locale(connection, inventory)
        database = connection.exec(Inventory::Production::DATABASE_SQL).first
        LOCALE_FIELDS.each do |field|
          fail!("run_server_locale_mismatch", field) unless database[field] == inventory.fetch("database")[field]
        end
        return if show(connection, "default_text_search_config") == inventory.fetch("default_text_search_config")

        fail!("run_server_locale_mismatch", "default_text_search_config")
      end

      # Production's value of a setting is the one the inventory recorded,
      # if it did. Otherwise, for a setting SETTINGS would list, it's the
      # built-in default: SETTINGS lists only settings that differ from it,
      # and the plan's didn't list this one. A setting SETTINGS never lists,
      # and the inventory didn't record, can't be known, so it fails.
      # Settings step 2 recorded that don't change plans, such as
      # shared_buffers and max_worker_processes, aren't compared.
      def check_planner_settings(connection, inventory)
        unlisted_ok = connection.exec(PLANNER_SQL).values.to_h
        names = (unlisted_ok.keys | inventory.fetch("plan_settings").keys).sort
        current = Inventory::Production.settings(connection, names)
        mismatch = first_mismatch(names, recorded_settings(inventory), unlisted_ok, current)
        fail!("run_server_guc_mismatch", mismatch) if mismatch
      end

      def first_mismatch(names, recorded, unlisted_ok, current)
        names.find { recorded.key?(it) ? recorded[it] != current[it] : unlisted_ok[it] != "t" }
      end

      # Every setting value step 2 recorded, by name.
      def recorded_settings(inventory)
        %w[parallel_settings settings plan_settings].map { inventory.fetch(it) }.reduce(:merge)
      end

      def check_quiet(connection, own_pids)
        pids = "{#{own_pids.join(",")}}"
        unless value(connection, CLIENTS_SQL, pids) == "0"
          raise Error.new("run_server_other_clients", "pg_stat_activity", clients: other_clients(connection, pids))
        end

        check_cron(connection)
        fail!("run_server_autovacuum_on", "autovacuum") unless show(connection, "autovacuum") == "off"
      end

      # The other clients' pids and start times, which are none if each one
      # left after the count. ErrorFilter sends no clients then.
      def other_clients(connection, pids)
        connection.exec_params(OTHER_CLIENTS_SQL, [pids]).values.map do |pid, started|
          { "pid" => Integer(pid, 10), "backend_start" => started }
        end
      end

      # pg_cron, when it's loaded, defines cron.database_name, the one
      # database it runs jobs from.
      def check_cron(connection)
        database = value(connection, "SELECT current_setting('cron.database_name', true)")
        fail!("run_server_cron_elsewhere", "cron.database_name") unless database.nil? || database == current(connection)
        return unless value(connection, "SELECT to_regclass('cron.job')")

        fail!("run_server_cron_active", "cron.job") unless value(connection, CRON_ACTIVE_SQL) == "0"
      end

      def fail!(rule, name) = raise(Error.new(rule, name))

      def show(connection, name) = value(connection, "SELECT current_setting($1)", name)

      def current(connection) = value(connection, "SELECT current_database()")

      # The first column of the first row, or nil if there's no row.
      def value(connection, sql, *params)
        result = connection.exec_params(sql, params)
        result.ntuples.zero? ? nil : result.getvalue(0, 0)
      end
    end
  end
end
