# frozen_string_literal: true

require "pg"
require_relative "../rewrite_assumptions"
require_relative "../run_discipline"

module Quaack
  module Enclave
    module AssumptionCheck
      # DESIGN.md's assumption-check's check of a denormalized_equal assumption (see
      # RewriteAssumptions), against the data:
      #
      #   DenormalizedEqual.met?(assumption, racetrack_connection)   # => true
      #
      # Met when no row of table, joined to references_table on join_column
      # = references_column, whose parent's type_column is type_value, has
      # column IS DISTINCT FROM the parent's id_column. It's one EXISTS
      # query, run as RunDiscipline runs a statement: alone, in a READ ONLY
      # transaction under a TIMEOUT_MS statement timeout, then rolled back.
      # A timeout or any error is unmet. Only the boolean comes back. The
      # type value goes in as a parameter, and every name as a quoted
      # identifier.
      module DenormalizedEqual
        TIMEOUT_MS = 300_000

        module_function

        def met?(assumption, connection)
          run = RunDiscipline.run(connection:, sql: sql(assumption, connection), timeout_ms: TIMEOUT_MS,
                                  params: [assumption["type_value"]])
          !run.timed_out && run.result.getvalue(0, 0) == "f"
        rescue PG::Error
          false
        end

        # Every comparison is pg_catalog's, so one planted ahead of it on
        # the search_path can't hide a row; a column type with no
        # pg_catalog = is an error, so unmet. IS DISTINCT FROM is written
        # out, since it can't name its operator.
        def sql(assumption, connection)
          name = ->(key) { connection.quote_ident(assumption[key]) }
          <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM #{table(assumption["table"], connection)} c
              JOIN #{table(assumption["references_table"], connection)} p
                ON c.#{name.call("join_column")} OPERATOR(pg_catalog.=) p.#{name.call("references_column")}
              WHERE p.#{name.call("type_column")} OPERATOR(pg_catalog.=) $1
                AND #{distinct("c.#{name.call("column")}", "p.#{name.call("id_column")}")})
          SQL
        end

        # left IS DISTINCT FROM right, by pg_catalog.=.
        def distinct(left, right)
          "NOT COALESCE(#{left} OPERATOR(pg_catalog.=) #{right}, #{left} IS NULL AND #{right} IS NULL)"
        end

        def table(name, connection) = RewriteAssumptions.split(name).map { connection.quote_ident(it) }.join(".")
      end
    end
  end
end
