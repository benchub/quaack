# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "tree"

module Quaack
  module Enclave
    module Fuzz
      # Whether a value passes a column's CHECKs, as Postgres judges them,
      # and the CHECKs' own constants, the only values a column they pin can
      # take. Each CHECK that reads only the column (Catalog#checks) is
      # tested over a one-row subselect naming the column. A value the
      # column's type can't read fails. Answers are kept.
      class Legal
        def initialize(conn, catalog)
          @conn = conn
          @catalog = catalog
          @answers = {}
          @constants = {}
        end

        def pinned?(table, column) = !@catalog.checks(table, column).empty?

        def call(table, column, value)
          return true unless pinned?(table, column)

          @answers.fetch([table, column, value]) { @answers[[table, column, value]] = test(table, column, value) }
        end

        def constants(table, column)
          @constants.fetch([table, column]) do
            found = @catalog.checks(table, column).flat_map { Tree.constants(PgQuery.parse("SELECT #{it}").tree.to_h) }
            @constants[[table, column]] = found.uniq.select { call(table, column, it) }
          end
        end

        private

        def test(table, column, value)
          tests = @catalog.checks(table, column).map { "(#{it}) IS NOT FALSE" }.join(" AND ")
          type = @catalog.column(table, column).type
          sql = "SELECT #{tests} FROM (SELECT CAST($1 AS #{type}) AS #{@conn.quote_ident(column)}) quaack_check"
          @conn.exec_params(sql, [value]).getvalue(0, 0) == "t"
        rescue PG::Error
          false
        end
      end
    end
  end
end
