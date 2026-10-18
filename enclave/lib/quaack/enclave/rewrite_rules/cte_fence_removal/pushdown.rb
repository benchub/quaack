# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../or_to_union/arms"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class CteFenceRemoval
        # Whether inlining a CTE could make Postgres raise where the
        # original doesn't.
        #
        # Stored, the CTE gives a reader only the rows its body keeps, so
        # a reader's condition runs only on those. Inlined, Postgres can
        # push the condition down to the body's tables, and run it before
        # the body's own WHERE or joins drop a row:
        #
        #   WITH m AS MATERIALIZED (SELECT o.total, o.qty FROM public.orders o JOIN public.users u ON ...)
        #   SELECT * FROM m WHERE m.total / m.qty > 3
        #
        # runs the division only on orders with a user. NOT MATERIALIZED,
        # it can run on every order, and divide by a qty of 0 that only an
        # order with no user has. So the rule refuses the CTE when a
        # condition that can raise (OrToUnion::Arms.raises?) could get
        # there, at any depth:
        #
        # - A condition of any SELECT outside the body: a conjunct of its
        #   WHERE, HAVING, or a join's ON, or a function in its FROM. One
        #   whose every column is written name.column, where name is a
        #   plain table in that SELECT's FROM, reads only that table's rows,
        #   which inlining doesn't change, so it can stay.
        # - An expression in the select list or VALUES of any SELECT but
        #   the query's output, inside the body or outside it. A condition
        #   on a column of that SELECT reads that expression in its place,
        #   so a condition that can't raise, such as m.ratio > 3, can raise
        #   when m.ratio is o.total / o.qty.
        #
        # An aggregate or window call doesn't count: it runs on the rows of
        # its own query once every condition of that query has passed, and
        # Postgres never pushes a condition that reads one down past them.
        # Its arguments see the same rows inlined or not. A call is an
        # aggregate when it has OVER or every function of its name is one.
        module Pushdown
          private

          def raises?(top, cte, catalog)
            body = Tree.find_all(cte.ctequery, PgQuery::SelectStmt)
            outputs = outputs(top)
            Tree.find_all(top, PgQuery::SelectStmt).any? do |select|
              (body.none? { it.equal?(select) } && conditions(select).any? { raising_read?(it, select, catalog) }) ||
                (outputs.none? { it.equal?(select) } && computed(select).any? { raising?(it, catalog) })
            end
          end

          # The statement, and if it's a set operation, each branch it's
          # made of: the SELECTs whose columns are the query's output.
          def outputs(select)
            return [select] if select.op == :SETOP_NONE

            [select, *outputs(select.larg), *outputs(select.rarg)]
          end

          def conditions(select)
            ons = select.from_clause.flat_map { Tree.joins(it) }.flat_map { Tree.conjuncts(it.quals) }
            [*Tree.conjuncts(select.where_clause), *Tree.conjuncts(select.having_clause), *ons,
             *Tree.find(select.from_clause, PgQuery::RangeFunction)]
          end

          def computed(select) = [*select.target_list.map { it.res_target.val }, *select.values_lists]

          def raising_read?(condition, select, catalog)
            raising?(condition, catalog) && !own_tables?(condition, select)
          end

          # Whether every column condition reads is written name.column, of
          # a plain table in select's FROM.
          def own_tables?(condition, select)
            Tree.find(condition, PgQuery::ColumnRef).all? do |ref|
              name = Tree.qualified(ref)&.first
              name && Tree.plain_table_named(select.from_clause, name)
            end
          end

          def raising?(node, catalog) = OrToUnion::Arms.raises?(without_aggregates(node, catalog), catalog)

          # A copy of node with each aggregate and window call in it a NULL.
          def without_aggregates(node, catalog)
            copy = Deparse.copy(node)
            calls(copy).each { it.a_const = PgQuery::A_Const.new(isnull: true) if aggregate?(it.func_call, catalog) }
            copy
          end

          # Every PgQuery::Node in node that holds a function call.
          def calls(node, found = [])
            case node
            when Google::Protobuf::RepeatedField then node.each { calls(it, found) }
            when Google::Protobuf::MessageExts
              found << node if node.is_a?(PgQuery::Node) && node.node == :func_call
              node.class.descriptor.each { calls(it.get(node), found) }
            end
            found
          end

          def aggregate?(call, catalog)
            names = call.funcname.map { it.string.sval }
            !call.over.nil? || catalog.only_aggregates?(names.length > 1 ? names[-2] : nil, names.last)
          end
        end
      end
    end
  end
end
