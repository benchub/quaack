# frozen_string_literal: true

require "pg"
require_relative "../rewrite_assumptions"
require_relative "../run_discipline"

module Quaack
  module Enclave
    module AssumptionCheck
      # DESIGN.md 6b's check of a denormalized_equal assumption (see
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

        def sql(assumption, connection)
          name = ->(key) { connection.quote_ident(assumption[key]) }
          <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM #{table(assumption["table"], connection)} c
              JOIN #{table(assumption["references_table"], connection)} p
                ON c.#{name.call("join_column")} = p.#{name.call("references_column")}
              WHERE p.#{name.call("type_column")} = $1
                AND c.#{name.call("column")} IS DISTINCT FROM p.#{name.call("id_column")})
          SQL
        end

        def table(name, connection) = RewriteAssumptions.split(name).map { connection.quote_ident(it) }.join(".")
      end
    end
  end
end
