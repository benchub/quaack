# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class NotInToNotExists
        # The nodes the rewrite builds.
        module Build
          module_function

          # The condition's SubLink as an EXISTS of the first branch.
          def exists_of(link, first)
            link.subselect = PgQuery::Node.new(select_stmt: first)
            link.sub_link_type = :EXISTS_SUBLINK
            link.testexpr = nil
            link.oper_name.clear
            link
          end

          # Makes the condition's Node NOT EXISTS, or an AND of one NOT EXISTS
          # for each branch, which a WHERE's own AND takes in.
          def replace!(found, link, branches)
            negated = PgQuery::Node.new(bool_expr: PgQuery::BoolExpr.new(
              boolop: :NOT_EXPR, args: [PgQuery::Node.new(sub_link: PgQuery::SubLink.decode(PgQuery::SubLink.encode(link)))]
            ))
            nots = [negated, *branches.drop(1).map { not_exists(it) }]
            found.node.bool_expr = Tree.all_of(nots).bool_expr
            flatten!(found) if found.conjunct && nots.size > 1
          end

          # Splices an AND made of the one condition into the WHERE's.
          def flatten!(found)
            found.owner.where_clause = Tree.all_of(Tree.conjuncts(found.owner.where_clause))
          end

          def not_exists(sub)
            link = PgQuery::SubLink.new(sub_link_type: :EXISTS_SUBLINK, subselect: PgQuery::Node.new(select_stmt: sub))
            PgQuery::Node.new(bool_expr: PgQuery::BoolExpr.new(boolop: :NOT_EXPR,
                                                               args: [PgQuery::Node.new(sub_link: link)]))
          end

          # The select list of SELECT 1.
          def one = Tree.exists.sub_link.subselect.select_stmt.target_list.to_a

          # tested = right, for a tested ColumnRef, which is copied, since
          # each branch's correlation has its own.
          def equals(tested, right)
            left = PgQuery::Node.new(column_ref: PgQuery::ColumnRef.decode(PgQuery::ColumnRef.encode(tested)))
            name = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))]
            PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name:, lexpr: left, rexpr: right))
          end
        end
      end
    end
  end
end
