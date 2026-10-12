# frozen_string_literal: true

require "pg"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Fuzz
      # The queries' constants dictionary for one column: each constant the
      # column's type can read, and its near neighbours at the type's
      # resolution (STEPS), finer than ValuePools'.
      class Dictionary
        STEPS = { "N" => ["1", "0.000001"],
                  "D" => ["1", "interval '1 second'", "interval '1 day'", "interval '1 microsecond'"] }.freeze

        def initialize(conn, constants)
          @conn = conn
          @constants = constants
          @categories = {}
        end

        def values(col)
          accepted = @constants.select { readable?(col, it) }
          accepted + accepted.flat_map { neighbours(col, it) }
        end

        def category(col) = @categories.fetch(col.oid) { @categories[col.oid] = ValuePools::Category.of(@conn, col) }

        private

        def readable?(col, value)
          @conn.exec_params("SELECT CAST($1 AS #{col.type})", [value])
          true
        rescue PG::Error
          false
        end

        def neighbours(col, value)
          STEPS.fetch(category(col), []).product(%w[+ -]).filter_map do |step, sign|
            sql = "SELECT (CAST($1 AS #{col.type}) OPERATOR(pg_catalog.#{sign}) #{step})::#{col.type}::pg_catalog.text"
            @conn.exec_params(sql, [value]).getvalue(0, 0)
          rescue PG::Error
            nil
          end
        end
      end
    end
  end
end
