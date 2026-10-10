# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class NotInToNotExists
        # The NOT INs and <> ALLs a statement's SELECTs each hold in their
        # own expressions, in any position: a WHERE, a HAVING, a select list,
        # a join's ON. A condition belongs to the nearest SELECT around it,
        # the one whose FROM its columns name.
        module Links
          # owner is the SELECT (never a set operation) whose scope the
          # condition is in, node the Node to replace (the NOT of a NOT IN,
          # or the <> ALL's own SubLink), link its SubLink, and conjunct
          # whether node is one of owner's WHERE's ANDed conditions.
          Link = Data.define(:owner, :node, :link, :conjunct)

          module_function

          # Every Link in the statement, in tree order.
          def all(tree)
            Tree.find_all(tree, PgQuery::SelectStmt).select { it.op == :SETOP_NONE }.flat_map { owned(it) }
          end

          # The Links in one SELECT's own expressions, none of a SELECT
          # inside it.
          def owned(select)
            found = []
            select.class.descriptor.each do |field|
              if field.name == "where_clause"
                Tree.conjuncts(select.where_clause).each { visit(select, it, found, conjunct: true) }
              else
                walk(select, field.get(select), found)
              end
            end
            found
          end

          def visit(owner, node, found, conjunct: false)
            sub = not_in(node) || all_sublink(node)
            if sub
              found << Link.new(owner:, node:, link: sub, conjunct:)
            elsif node.node != :select_stmt
              walk(owner, node.inner, found)
            end
          end

          def walk(owner, node, found)
            case node
            when Google::Protobuf::RepeatedField then node.each { walk(owner, it, found) }
            when PgQuery::Node then visit(owner, node, found)
            when Google::Protobuf::MessageExts
              node.class.descriptor.each { walk(owner, it.get(node), found) }
            end
          end

          # The SubLink of NOT (x IN (SELECT ...)), or nil.
          def not_in(node)
            inner = negated(node)
            sub = inner.sub_link if inner&.node == :sub_link
            sub if sub && sub.sub_link_type == :ANY_SUBLINK && sub.oper_name.empty? && shaped?(sub)
          end

          # What a NOT of one condition negates, or nil.
          def negated(node)
            node.bool_expr.args.first if node.node == :bool_expr && node.bool_expr.boolop == :NOT_EXPR &&
                                         node.bool_expr.args.size == 1
          end

          # The SubLink of x <> ALL (SELECT ...), or nil.
          def all_sublink(node)
            return unless node.node == :sub_link

            sub = node.sub_link
            names = sub.oper_name.map { it.string&.sval }
            sub if sub.sub_link_type == :ALL_SUBLINK && names == ["<>"] && shaped?(sub)
          end

          def shaped?(sub) = sub.testexpr && sub.subselect.node == :select_stmt
        end
      end
    end
  end
end
