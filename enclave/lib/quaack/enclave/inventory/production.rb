# frozen_string_literal: true

require "json"
require "pg"
require_relative "error"
require_relative "../connections"
require_relative "../error_filter"

module Quaack
  module Enclave
    module Inventory
      # The production server's side of inventory (DESIGN.md): connect to it, and
      # read what the inventory records, inside one read-only transaction.
      #
      # It connects with the operator's own libpq setup on the jump server.
      # Only the host, and the port when intake had --port, come from the
      # run (params). Everything else, the user, the database, the password,
      # and the port without --port, comes from where libpq looks for it:
      # PGUSER and the other PG environment variables, a service from
      # ~/.pg_service.conf named by PGSERVICE, and ~/.pgpass. QUAACK stores
      # no credentials. Every step that reaches production, schema-dump's
      # pg_dump included, takes its connection parameters from params, so
      # none can leave the port out.
      #
      # Every error is an Error with only its rule, and the SQLSTATE when
      # Postgres sent one: libpq's and Postgres's messages can name the host,
      # the user, the database, or a value.
      module Production
        # Far longer than any catalog read takes, and a step that reads
        # production still ends when one hangs.
        STATEMENT_TIMEOUT = "60s"
        TIMEOUT_SQL = "SELECT pg_catalog.set_config('statement_timeout', $1, true)"
        # Postgres 17 added pg_database.datlocale.
        OLDEST_MAJOR = 17
        # DESIGN.md's inventory, in its order. The last four change plans, or how
        # a literal is read, but EXPLAIN's SETTINGS never lists them, so
        # run-server (RunServerCheck) needs production's values from here.
        SETTINGS = %w[shared_buffers effective_cache_size work_mem random_page_cost jit
                      TimeZone DateStyle IntervalStyle default_statistics_target].freeze

        # Each setting's name and value, as SHOW prints it, for the names in
        # the JSON array $1. A name production doesn't know gets NULL.
        SETTINGS_SQL = "SELECT name, pg_catalog.current_setting(name, true) " \
                       "FROM pg_catalog.json_array_elements_text($1::json) AS name"
        # Every setting named for parallel query, plus two that parallel
        # plans depend on without the word in their names:
        # max_worker_processes, the pool parallel workers come from, and
        # enable_gathermerge, which turns on the Gather Merge node.
        PARALLEL_SQL = "SELECT name, pg_catalog.current_setting(name) FROM pg_catalog.pg_settings " \
                       "WHERE name OPERATOR(pg_catalog.~~) '%parallel%' OR name OPERATOR(pg_catalog.=) " \
                       "ANY ('{max_worker_processes,enable_gathermerge}'::pg_catalog.text[]) " \
                       "ORDER BY name"
        EXTENSIONS_SQL = "SELECT extname, extversion FROM pg_catalog.pg_extension ORDER BY extname"
        DATABASE_SQL = "SELECT datname, datcollate, datctype, datlocprovider::pg_catalog.text, datlocale, " \
                       "datcollversion " \
                       "FROM pg_catalog.pg_database WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database()"
        # Each tablespace's name and its spcoptions, sorted, as a JSON array.
        # A tablespace's random_page_cost and seq_page_cost override the
        # settings' for the relations in it.
        TABLESPACE_COLUMNS = "spcname, pg_catalog.array_to_json(ARRAY(" \
                             "SELECT o FROM pg_catalog.unnest(spcoptions) AS o ORDER BY o))::pg_catalog.text"
        # The tablespaces this database's relations use: its default, which
        # a relation whose reltablespace is 0 is in, and every other one a
        # relation names. pg_global holds only the shared catalogs.
        TABLESPACES_SQL = "SELECT #{TABLESPACE_COLUMNS} FROM pg_catalog.pg_tablespace " \
                          "WHERE oid OPERATOR(pg_catalog.=) ANY (ARRAY(" \
                          "SELECT dattablespace FROM pg_catalog.pg_database " \
                          "WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database() " \
                          "UNION SELECT reltablespace FROM pg_catalog.pg_class)) " \
                          "AND spcname OPERATOR(pg_catalog.<>) 'pg_global' ORDER BY spcname".freeze
        # pg_settings leaves shared_preload_libraries out for a role without
        # pg_read_all_settings, where current_setting would fail.
        PRELOAD_SQL = "SELECT setting FROM pg_catalog.pg_settings " \
                      "WHERE name OPERATOR(pg_catalog.=) 'shared_preload_libraries'"

        module_function

        # The run's production connection parameters: its server as host,
        # its production_port as port, and its production_database as
        # dbname, each only if intake stored one.
        def params(store)
          port = store.read("production_port") if store.entry?("production_port")
          dbname = store.read("production_database") if store.entry?("production_database")
          { host: store.read("server"), **(port ? { port: } : {}), **(dbname ? { dbname: } : {}) }
        end

        # A connection with params, its notices dropped (see Connections).
        def connect(params)
          Connections.register(PG.connect(**params))
        rescue PG::Error
          raise Error, "production_connection_failed", cause: nil
        end

        # The inventory, as a Hash of plain JSON data for the store.
        # plan_settings names the settings the input plan's SETTINGS lists.
        def read(connection, plan_settings:)
          read_only(connection) do
            version_num = Integer(connection.exec("SHOW server_version_num").getvalue(0, 0), 10)
            { "server_version_num" => version_num, "major_version" => major_version(version_num),
              **catalog(connection, plan_settings) }
          end
        end

        def catalog(connection, plan_settings)
          {
            "extensions" => pairs(connection.exec(EXTENSIONS_SQL)),
            "settings" => settings(connection, SETTINGS),
            "parallel_settings" => pairs(connection.exec(PARALLEL_SQL)),
            "plan_settings" => settings(connection, plan_settings),
            "database" => connection.exec(DATABASE_SQL).first,
            "default_text_search_config" => connection.exec("SHOW default_text_search_config").getvalue(0, 0),
            "tablespaces" => tablespaces(connection.exec(TABLESPACES_SQL)),
            "preload_libraries" => library_names(connection.exec(PRELOAD_SQL).first&.fetch("setting"))
          }
        end

        # A tablespace query's rows, as each name and its sorted options.
        def tablespaces(result) = result.values.to_h { |name, options| [name, JSON.parse(options)] }

        # The libraries a shared_preload_libraries value names, each as its
        # file's base name without .so, since Postgres loads
        # '$libdir/pg_hint_plan.so' and pg_hint_plan alike. nil, for a value
        # the role can't see, stays nil.
        def library_names(value)
          value&.split(",")&.map { File.basename(it.strip.delete('"'), ".so") }&.reject(&:empty?)
        end

        # Runs the block inside a read-only, repeatable read transaction on
        # connection, so every read sees one snapshot and nothing can be
        # written, and rolls it back after. The transaction has
        # statement_timeout, STATEMENT_TIMEOUT unless it's given, so a read
        # that hangs on production fails. A Postgres error in the block,
        # or in starting or ending the transaction, a timeout's 57014
        # included, is production_read_failed, with its SQLSTATE.
        def read_only(connection, statement_timeout: STATEMENT_TIMEOUT)
          connection.exec("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
          begin
            connection.exec_params(TIMEOUT_SQL, [statement_timeout])
            yield
          ensure
            connection.exec("ROLLBACK")
          end
        rescue PG::Error => e
          raise Error.new("production_read_failed", sqlstate: sqlstate(e)), cause: nil
        end

        # The major version of a server_version_num, such as 18 for 180001.
        def major_version(version_num)
          major = version_num / 10_000
          raise Error, "unsupported_production_version" if major < OLDEST_MAJOR

          major
        end

        def settings(connection, names) = pairs(connection.exec_params(SETTINGS_SQL, [JSON.generate(names)]))

        def pairs(result) = result.values.to_h

        def sqlstate(error) = error.result&.error_field(ErrorFilter::PG_DIAG_SQLSTATE)
      end
    end
  end
end
