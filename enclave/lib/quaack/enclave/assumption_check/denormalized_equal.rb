# frozen_string_literal: true

require "pg"
require_relative "../rewrite_assumptions"
require_relative "../run_discipline"
require_relative "equality"

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

        # A comparison with no = of the application's (see Equality).
        class Unmet < StandardError; end

        # A column in the query: how it's written, and its base type's oid
        # and quoted name.
        Column = Data.define(:sql, :type, :type_name)

        module_function

        def met?(assumption, connection)
          run = RunDiscipline.run(connection:, sql: sql(assumption, connection), timeout_ms: TIMEOUT_MS,
                                  params: [assumption["type_value"]])
          !run.timed_out && run.result.getvalue(0, 0) == "f"
        rescue PG::Error, Unmet
          false
        end

        # Every comparison of user columns is the = of the columns' types
        # (see Equality), named with its schema, so one planted ahead of it
        # on the search_path can't hide a row, and citext's stays citext's.
        # IS DISTINCT FROM is written out, since it can't name its operator.
        def sql(assumption, connection)
          child, parent = %w[table references_table].map { table(assumption[it], connection) }
          joined, typed, same = conditions(assumption, connection, child, parent)
          <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM #{child} c JOIN #{parent} p ON #{joined}
              WHERE #{typed} AND NOT COALESCE(#{same}))
          SQL
        end

        # The join, the filter on the parent's type, and the comparison of
        # the copy with the parent's id.
        def conditions(assumption, connection, child, parent)
          column = ->(table, as, key) { column(connection, table, as, assumption[key]) }
          kind = column.call(parent, "p", "type_column")
          [[column.call(child, "c", "join_column"), column.call(parent, "p", "references_column")],
           [kind, kind.with(sql: "$1::#{kind.type_name}")],
           [column.call(child, "c", "column"), column.call(parent, "p", "id_column"), true]]
            .map { |left, right, nulls| compare(connection, left, right, nulls:) }
        end

        def column(connection, table, as, name)
          type = Equality.column_type(connection, table, name) or raise Unmet
          sql = "#{as}.#{connection.quote_ident(name)}"
          Column.new(sql:, **%i[type type_name].zip(Equality.base(connection, type)).to_h)
        end

        # left = right by their types' =, and with nulls, also true when
        # both are NULL, as IS NOT DISTINCT FROM is.
        def compare(connection, left, right, nulls: false)
          eq = Equality.operator(connection, left.type, right.type) or raise Unmet
          both_null = ", #{left.sql} IS NULL AND #{right.sql} IS NULL" if nulls
          "#{left.sql} #{eq} #{right.sql}#{both_null}"
        end

        def table(name, connection) = RewriteAssumptions.split(name).map { connection.quote_ident(it) }.join(".")
      end
    end
  end
end
