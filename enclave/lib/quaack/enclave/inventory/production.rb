# frozen_string_literal: true

require "json"
require "pg"
require_relative "error"
require_relative "../connections"
require_relative "../error_filter"

module Quaack
  module Enclave
    module Inventory
      # The production server's side of step 2 (DESIGN.md): connect to it, and
      # read what the inventory records, inside one read-only transaction.
      #
      # It connects with the operator's own libpq setup on the jump server.
      # Only the host comes from the run. Everything else, the port, the
      # user, the database, and the password, comes from where libpq looks
      # for it: PGUSER and the other PG environment variables, a service
      # from ~/.pg_service.conf named by PGSERVICE, and ~/.pgpass. QUAACK
      # stores no credentials.
      #
      # Every error is an Error with only its rule, and the SQLSTATE when
      # Postgres sent one: libpq's and Postgres's messages can name the host,
      # the user, the database, or a value.
      module Production
        # Postgres 17 added pg_database.datlocale.
        OLDEST_MAJOR = 17
        # DESIGN.md, step 2, in its order. The last four change plans, or how
        # a literal is read, but EXPLAIN's SETTINGS never lists them, so
        # step 4 (RunServerCheck) needs production's values from here.
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
                       "WHERE name LIKE '%parallel%' OR name IN ('max_worker_processes', 'enable_gathermerge') " \
                       "ORDER BY name"
        EXTENSIONS_SQL = "SELECT extname, extversion FROM pg_catalog.pg_extension ORDER BY extname"
        DATABASE_SQL = "SELECT datname, datcollate, datctype, datlocprovider::pg_catalog.text, datlocale, " \
                       "datcollversion " \
                       "FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()"

        module_function

        # A connection to host, its notices dropped (see Connections).
        def connect(host)
          Connections.register(PG.connect(host:))
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
            "default_text_search_config" => connection.exec("SHOW default_text_search_config").getvalue(0, 0)
          }
        end

        # Runs the block inside a read-only, repeatable read transaction on
        # connection, so every read sees one snapshot and nothing can be
        # written, and rolls it back after. A Postgres error in the block,
        # or in starting or ending the transaction, is
        # production_read_failed, with its SQLSTATE.
        def read_only(connection)
          connection.exec("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
          begin
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
