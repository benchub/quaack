# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The order IndexBuild builds its indexes in (20261004-12), which
    # `quaacks index-build --index <n>` counts in too.
    module BuildOrder
      module_function

      # combinations' distinct DDL, grouped by schema-qualified table, so
      # every index on one table is built while it's still in cache. Tables
      # go in the order each first appears, and each table's indexes keep
      # the order they came in.
      def ddls(combinations) = combinations.values.flatten.uniq.group_by { table(it) }.values.flatten

      def table(ddl) = PgQuery.parse(ddl).tree.stmts.first.stmt.index_stmt.relation.then { [it.schemaname, it.relname] }
    end
  end
end
