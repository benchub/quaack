# frozen_string_literal: true

require_relative "../inventory/production"

module Quaack
  module Enclave
    module RunServerCheck
      # RunServerCheck's checks of what the run server holds outside its
      # settings, against production's inventory:
      #
      # - run_server_tablespace_mismatch: a tablespace production's
      #   relations use isn't on the run server by name, or its spcoptions
      #   aren't production's. Its name is production configuration, so the
      #   Error names only spcoptions.
      # - run_server_preload_mismatch: one side preloads one of
      #   PLANNER_LIBRARIES and the other doesn't. The Error names it.
      module ServerOptions
        # Every tablespace but pg_global, which holds only the shared catalogs.
        TABLESPACES_SQL = "SELECT #{Inventory::Production::TABLESPACE_COLUMNS} FROM pg_catalog.pg_tablespace " \
                          "WHERE spcname OPERATOR(pg_catalog.<>) 'pg_global'".freeze
        # Libraries that change plans just by being preloaded: pg_hint_plan
        # reads hints and its hint table, pg_dbms_stats swaps in locked
        # statistics, plantuner hides indexes, and aqo corrects row
        # estimates. Others, such as pg_stat_statements, auto_explain, and
        # pg_qualstats, only watch, and managed services preload their own,
        # such as rdsutils, that no other server can load, so only these
        # are compared.
        PLANNER_LIBRARIES = %w[pg_hint_plan pg_dbms_stats plantuner aqo].freeze

        module_function

        def check(connection, inventory)
          check_tablespaces(connection, inventory)
          check_preload(connection, inventory)
        end

        def check_tablespaces(connection, inventory)
          here = Inventory::Production.tablespaces(connection.exec(TABLESPACES_SQL))
          return if inventory.fetch("tablespaces").all? { |name, options| here[name] == options }

          RunServerCheck.fail!("run_server_tablespace_mismatch", "spcoptions")
        end

        def check_preload(connection, inventory)
          here = Inventory::Production.library_names(
            RunServerCheck.value(connection, Inventory::Production::PRELOAD_SQL)
          )
          mismatch = preload_mismatch(inventory.fetch("preload_libraries"), here)
          RunServerCheck.fail!("run_server_preload_mismatch", mismatch) if mismatch
        end

        # The first of PLANNER_LIBRARIES that one list preloads and the
        # other doesn't, or nil. A production list inventory couldn't see
        # is nil, and isn't compared.
        def preload_mismatch(production, here)
          return nil if production.nil?

          PLANNER_LIBRARIES.find { production.include?(it) != here.include?(it) }
        end
      end
    end
  end
end
