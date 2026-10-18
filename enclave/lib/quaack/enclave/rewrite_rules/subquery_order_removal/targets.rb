# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class SubqueryOrderRemoval
        # Finds the SELECTs whose ORDER BY the rule could drop, each with
        # the SELECTs that read its rows.
        #
        # Targets.in(tree) gives, in tree order, a Target for:
        #
        # - each subquery in a FROM, LATERAL ones and those under a join
        #   included. Its one reader is the SELECT whose FROM it's in.
        # - each CTE body that is a SELECT. Its readers are every SELECT in
        #   the WITH's own SELECT, the other CTE bodies included, that has
        #   the CTE's name in its FROM as a table with no schema.
        #
        # A CTE of a RECURSIVE WITH, and one whose name another CTE in the
        # statement also has, get no readers, so the rule leaves them
        # alone. With a name of its own, every table with no schema that
        # has its name, in the WITH's SELECT, is the CTE, since QUAACK
        # qualifies every table the query names before the rules run. Each
        # SELECT is found the same way in a copy of the tree, which is how
        # a rewrite finds the one it changes.
        module Targets
          Target = Data.define(:select, :readers)

          module_function

          def in(tree)
            return [] unless Tree.select(tree)

            names = Tree.find_all(tree, PgQuery::CommonTableExpr).map(&:ctename).tally
            Tree.find_all(tree, PgQuery::SelectStmt).flat_map { ctes(it, names) + derived(it) }
          end

          def ctes(select, names)
            clause = select.with_clause
            return [] unless clause

            clause.ctes.map(&:common_table_expr).select { it.ctequery.node == :select_stmt }.map do |cte|
              shared = clause.recursive || names[cte.ctename] > 1
              Target.new(select: cte.ctequery.select_stmt, readers: shared ? [] : readers(select, cte.ctename))
            end
          end

          def derived(select)
            leaves(select.from_clause).select { it.node == :range_subselect }.map do |item|
              Target.new(select: item.range_subselect.subquery.select_stmt, readers: [select])
            end
          end

          # Every SELECT in scope with name in its FROM as a table with no
          # schema.
          def readers(scope, name)
            Tree.find_all(scope, PgQuery::SelectStmt).select do |select|
              leaves(select.from_clause).any? do |item|
                item.node == :range_var && item.range_var.schemaname.empty? && item.range_var.relname == name
              end
            end
          end

          # A FROM clause's items, with each join's two sides in its place.
          def leaves(nodes)
            nodes.flat_map { it.node == :join_expr ? leaves([it.join_expr.larg, it.join_expr.rarg]) : [it] }
          end
        end
      end
    end
  end
end
