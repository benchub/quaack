# frozen_string_literal: true

require_relative "../../assumption_check"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # Whether a column's comparisons are its type's default btree
        # family's, for a rule that relies on them agreeing. Each answer is
        # kept for the life of the Catalog.
        module Btree
          EQ = "OPERATOR(pg_catalog.=)"

          # The column type's default btree operator family: the type's own
          # default btree opclass, or failing that the one opclass of a
          # preferred type it coerces to without a function, as varchar does to
          # text, which is how Postgres picks varchar's =. A domain, an enum, or
          # an array has neither, so it has none.
          BTREE_FAMILY = <<~SQL.freeze
            WITH col AS (
              SELECT a.atttypid AS type FROM pg_catalog.pg_attribute a
              WHERE a.attrelid #{EQ} #{AssumptionCheck::RELATION} AND a.attname #{EQ} $3 AND a.attnum OPERATOR(pg_catalog.>) 0
            ), opclasses AS (
              SELECT c.opcfamily, c.opcintype, c.opcintype #{EQ} col.type AS exact, t.typispreferred AS preferred
              FROM col
              JOIN pg_catalog.pg_opclass c ON c.opcdefault
              JOIN pg_catalog.pg_am am ON am.oid #{EQ} c.opcmethod AND am.amname #{EQ} 'btree'
              JOIN pg_catalog.pg_type t ON t.oid #{EQ} c.opcintype
              WHERE c.opcintype #{EQ} col.type
                 OR EXISTS (SELECT 1 FROM pg_catalog.pg_cast k
                            WHERE k.castsource #{EQ} col.type AND k.casttarget #{EQ} c.opcintype
                              AND k.castmethod #{EQ} 'b')
            )
            SELECT o.opcfamily, col.type FROM opclasses o, col
            WHERE o.exact OR (o.preferred AND NOT EXISTS (SELECT 1 FROM opclasses e WHERE e.exact))
          SQL

          # How many operators named =, <, <=, >, or >= between two of the
          # column's type ($2) aren't in the family ($1) under that name.
          # Postgres picks an operator taking exactly the column's type over
          # any other.
          BTREE_OPERATORS = <<~SQL.freeze
            WITH strategies (strategy, name) AS (VALUES (1, '<'), (2, '<='), (3, '='), (4, '>='), (5, '>'))
            SELECT pg_catalog.count(*) FROM strategies s
            JOIN pg_catalog.pg_operator op ON op.oprname #{EQ} s.name AND op.oprleft #{EQ} $2 AND op.oprright #{EQ} $2
            WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_amop o
                              WHERE o.amopfamily #{EQ} $1 AND o.amopopr #{EQ} op.oid
                                AND o.amopstrategy #{EQ} s.strategy)
          SQL

          # Whether =, <, <=, >, and >= between two values of the column's type
          # are the operators of its default btree family, so values that = calls
          # equal compare alike under all five.
          def default_btree?(schema, table, column)
            (@default_btree ||= {}).fetch([schema, table, column]) do
              @default_btree[[schema, table, column]] = default_btree_family?(schema, table, column)
            end
          end

          # Whether Postgres takes = between two columns, each [schema,
          # table, column], as one pair of a row comparison: it does only
          # when that = is an operator of a btree family, which box's isn't.
          # It asks Postgres, with the connection's search path, by
          # preparing a comparison of the pair beside a pair of booleans,
          # since a row of one column isn't held to that.
          def row_equality?(left, right)
            (@row_equality ||= {}).fetch([left, right]) do
              @row_equality[[left, right]] =
                self_contained?("SELECT FROM #{relation(left)} l, #{relation(right)} r " \
                                "WHERE (l.#{@connection.quote_ident(left.last)}, true) = " \
                                "(r.#{@connection.quote_ident(right.last)}, true)")
            end
          end

          # Whether Postgres can dedupe a column, [schema, table, column], in
          # a UNION: its type has an equality to sort or hash by, which box's
          # = isn't. It asks Postgres, as row_equality? does.
          def unionable?(column)
            (@unionable ||= {}).fetch(column) do
              read = "SELECT l.#{@connection.quote_ident(column.last)} FROM #{relation(column)} l"
              @unionable[column] = self_contained?("#{read} UNION #{read}")
            end
          end

          private

          def relation((schema, table)) = "#{@connection.quote_ident(schema)}.#{@connection.quote_ident(table)}"

          def default_btree_family?(schema, table, column)
            families = @connection.exec_params(BTREE_FAMILY, [schema, table, column]).values
            return false unless families.size == 1

            @connection.exec_params(BTREE_OPERATORS, families.first).getvalue(0, 0) == "0"
          end
        end
      end
    end
  end
end
