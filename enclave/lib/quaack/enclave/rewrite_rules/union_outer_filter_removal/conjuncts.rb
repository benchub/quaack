# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class UnionOuterFilterRemoval
        # Reading a conjunct's own columns and subqueries. A column inside
        # a subquery belongs to the subquery, so these never look in a
        # SubLink's SELECT, only at what it's tested against.
        module Conjuncts
          module_function

          # Every message in node outside a subquery's SELECT.
          def outside(node, &)
            case node
            when Google::Protobuf::RepeatedField then node.each { outside(it, &) }
            when Google::Protobuf::MessageExts
              yield node
              fields(node).each { outside(it.get(node), &) }
            end
          end

          def columns(node) = enum_for(:outside, node).grep(PgQuery::ColumnRef)

          def sublinks(node) = enum_for(:outside, node).grep(PgQuery::SubLink)

          # node, changed in place, with each column outside a subquery's
          # SELECT replaced by what the block gives for its ColumnRef.
          def map_columns(node, &)
            case node
            when Google::Protobuf::RepeatedField then node.each_with_index { |child, i| node[i] = map_columns(child, &) }
            when PgQuery::Node
              return yield(node.column_ref) if node.node == :column_ref

              map_fields(node, &)
            when Google::Protobuf::MessageExts then map_fields(node, &)
            end
            node
          end

          def map_fields(node, &)
            fields(node).each do |field|
              value = field.get(node)
              next unless value.is_a?(Google::Protobuf::MessageExts) || value.is_a?(Google::Protobuf::RepeatedField)

              mapped = map_columns(value, &)
              field.set(node, mapped) unless mapped.equal?(value)
            end
          end

          def fields(node)
            node.class.descriptor.reject { node.is_a?(PgQuery::SubLink) && it.name == "subselect" }
          end

          # A SELECT of one subquery under the top-level WITH, which
          # Postgres can analyze alone only if every name in the subquery
          # resolves inside it or to the top-level WITH.
          def standalone(sublink, top)
            select = PgQuery.parse("SELECT 1 FROM (SELECT 1) q").tree.stmts.first.stmt.select_stmt
            select.from_clause.first.range_subselect.subquery = Deparse.copy(sublink.subselect)
            select.with_clause = Deparse.copy(top.with_clause) if top.with_clause
            select
          end

          # SELECT WHERE condition.
          def filter(condition)
            select = PgQuery.parse("SELECT WHERE true").tree.stmts.first.stmt.select_stmt
            select.where_clause = Deparse.copy(condition)
            select
          end
        end
      end
    end
  end
end
