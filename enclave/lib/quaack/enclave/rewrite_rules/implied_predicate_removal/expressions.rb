# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ImpliedPredicateRemoval
        module Expressions
          SAFE_NODES = [PgQuery::Node, PgQuery::A_Const, PgQuery::A_Expr, PgQuery::BoolExpr, PgQuery::ColumnRef,
                        PgQuery::ParamRef, PgQuery::TypeCast, PgQuery::TypeName, PgQuery::List,
                        PgQuery::String, PgQuery::Integer].freeze

          def same_column?(one, other) = Tree.qualified(one) == Tree.qualified(other)

          def columns(node) = Tree.find(node, PgQuery::ColumnRef)

          def safe?(node)
            case node
            when Google::Protobuf::RepeatedField then node.all? { safe?(it) }
            when Google::Protobuf::MessageExts then safe_message?(node)
            else true
            end
          end

          def safe_message?(node)
            SAFE_NODES.include?(node.class) && node.class.descriptor.all? { |field| safe?(field.get(node)) }
          end

          def replace_column(node, column, replacement)
            replace(Deparse.copy(node), column, replacement)
          end

          def replace(node, column, replacement)
            return Deparse.copy(replacement) if target_column?(node, column)
            return replace_repeated(node, column, replacement) if node.is_a?(Google::Protobuf::RepeatedField)
            return replace_message(node, column, replacement) if node.is_a?(Google::Protobuf::MessageExts)

            node
          end

          def target_column?(node, column)
            node.is_a?(PgQuery::Node) && node.node == :column_ref && same_column?(node.column_ref, column)
          end

          def replace_repeated(nodes, column, replacement)
            nodes.each_with_index { |child, i| nodes[i] = replace(child, column, replacement) }
            nodes
          end

          def replace_message(node, column, replacement)
            node.class.descriptor.each { replace_field(node, it, column, replacement) }
            node
          end

          def replace_field(node, field, column, replacement)
            return if Deparse.location?(field)

            current = field.get(node)
            replaced = replace(current, column, replacement)
            field.set(node, replaced) unless replaced.equal?(current)
          end

          def same_expression?(one, other, literals)
            left = comparable_node(one)
            right = comparable_node(other)
            same_node?(left, right, literals)
          end

          def comparable_node(node)
            copy = Deparse.copy(node)
            Deparse.clear_locations(copy)
            copy
          end

          def same_node?(one, other, literals)
            return same_param?(one, other, literals) if one.is_a?(PgQuery::ParamRef) || other.is_a?(PgQuery::ParamRef)
            return one == other unless one.instance_of?(other.class)
            return same_repeated?(one, other, literals) if one.is_a?(Google::Protobuf::RepeatedField)
            return same_message?(one, other, literals) if one.is_a?(Google::Protobuf::MessageExts)

            one == other
          end

          def same_repeated?(one, other, literals)
            one.size == other.size && one.each_with_index.all? { |child, i| same_node?(child, other[i], literals) }
          end

          def same_message?(one, other, literals)
            one.class.descriptor.all? { |field| same_node?(field.get(one), field.get(other), literals) }
          end

          def same_param?(one, other, literals)
            one.is_a?(PgQuery::ParamRef) && other.is_a?(PgQuery::ParamRef) &&
              literals.same?("$#{one.number}", "$#{other.number}")
          end
        end
      end
    end
  end
end
