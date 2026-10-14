# frozen_string_literal: true

require "pg"

module Quaack
  module Enclave
    module Fuzz
      # The values at which a column the queries combine with a number
      # crosses the number they compare the result with (Facts'
      # combinations): 100 / points > 2 crosses at 50, and
      # points * 0.9 >= 45 at 50 too. Each solution, then its ceiling and
      # floor, which an integer column can hold, in the queries' order.
      #
      #   Thresholds.new(conn, facts).values(table, "points")  # => ["50", "33.3333333333333333", "34", "33"]
      #
      # A column's solutions go to its table's column where the query
      # qualifies it, and to every table's column of its name where it
      # doesn't (Facts' combinations).
      #
      # A solution needs a nonzero divisor (a division by zero, or a
      # constant numeric can't hold, gives none), and a column combined
      # with another column (score / points >= 0.9) gives none. Solved in
      # Postgres's numeric, as text. Trust boundary: these are functions of
      # the queries' constants, so they stay in the enclave.
      class Thresholds
        # column op constant = compared, solved for column, with $1 the
        # constant and $2 compared, by operator and whether the column
        # comes first.
        SOLUTIONS = {
          ["+", true] => "$2 OPERATOR(pg_catalog.-) $1", ["+", false] => "$2 OPERATOR(pg_catalog.-) $1",
          ["-", true] => "$2 OPERATOR(pg_catalog.+) $1", ["-", false] => "$1 OPERATOR(pg_catalog.-) $2",
          ["*", true] => "$2 OPERATOR(pg_catalog./) $1", ["*", false] => "$2 OPERATOR(pg_catalog./) $1",
          ["/", true] => "$2 OPERATOR(pg_catalog.*) NULLIF($1, 0)", ["/", false] => "$1 OPERATOR(pg_catalog./) $2"
        }.freeze

        def initialize(conn, facts)
          @conn = conn
          @facts = facts
        end

        def values(table, column)
          @facts.combinations.select { it.column == column && [nil, table].include?(it.table) }
                .flat_map { solve(it) }.uniq
        end

        private

        def solve(combination)
          expression = SOLUTIONS.fetch([combination.operator, combination.column_first])
                                .gsub(/\$\d/) { "#{it}::pg_catalog.numeric" }
          sql = "SELECT pg_catalog.trim_scale(s)::pg_catalog.text, pg_catalog.ceil(s)::pg_catalog.text, " \
                "pg_catalog.floor(s)::pg_catalog.text " \
                "FROM (SELECT #{expression} AS s) AS solved WHERE s IS NOT NULL"
          @conn.exec_params(sql, [combination.constant, combination.compared]).values.flatten
        rescue PG::Error
          []
        end
      end
    end
  end
end
