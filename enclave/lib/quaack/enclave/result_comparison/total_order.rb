# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparison
      # A nondeterministic collation makes the ordered comparison refuse,
      # since values it calls equal, such as 'a' and 'A', can tie in the
      # sort and print differently. That can't happen when the original's
      # ORDER BY is a total order fixed by the data: its top SELECT is
      # deterministic as an inner cut would be (InnerCuts: one table read
      # once, which a WHERE's IN or EXISTS semijoin never repeats, no GROUP
      # BY, DISTINCT, or set operation, sorted by every column of a
      # not-null unique key), and that key's columns have deterministic
      # collations. Then the original's rows have one order, and the two
      # results compare row for row. A candidate that ties can only lose.
      module TotalOrder
        # Keeps only keys whose columns have no collation or a deterministic one.
        DETERMINISTIC_KEYS_SQL = <<~SQL
          AND NOT EXISTS (
            SELECT FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_collation co ON co.oid OPERATOR(pg_catalog.=) a.attcollation
            WHERE a.attrelid OPERATOR(pg_catalog.=) i.indrelid
              AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey::pg_catalog.int2[]) AND NOT co.collisdeterministic)
        SQL

        module_function

        # :none when neither shape meets a nondeterministic collation,
        # :total when one does but the original's order is total, and nil,
        # to refuse, otherwise.
        def gate(transaction, shapes)
          return :none unless Tiebreaker.nondeterministic_collation?(transaction, shapes.flat_map(&:collation_names))

          tree = shapes.first.tree
          top = tree[:stmts].first[:stmt][:select_stmt]
          :total if InnerCuts.deterministic?(transaction, top, InnerCuts.cte_names(tree), DETERMINISTIC_KEYS_SQL)
        end

        # The original's order is total, so the results compare row for row.
        def compare(transaction, *shapes)
          ResultComparator.compare(*shapes.map { transaction.query(it.sql) }, mode: :ordered)
        end
      end
    end
  end
end
