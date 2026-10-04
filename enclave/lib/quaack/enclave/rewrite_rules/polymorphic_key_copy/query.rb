# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class PolymorphicKeyCopy
        # What polymorphic_key_copy reads from one SELECT: its top-level
        # conjuncts, from the WHERE and every inner join's ON, and the
        # joins child.<x> = parent.id among them, with the parent's
        # <p>_type = $m and <p>_id = $n filters.
        class Query
          # A parent column's filter to a bare placeholder.
          Filter = Data.define(:column, :param)
          # qualifier is the name the query reads the child by.
          Join = Data.define(:query, :child, :parent, :qualifier, :child_column, :pairs)

          # qualifier.column = $param, as a node.
          def self.equality(qualifier, column, param)
            fields = [qualifier, column].map { PgQuery::Node.new(string: PgQuery::String.new(sval: it)) }
            PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(
              kind: :AEXPR_OP, name: [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))],
              lexpr: PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields:)),
              rexpr: PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: param))
            ))
          end

          def initialize(select)
            @select = select
            ons = select.from_clause.flat_map { Tree.joins(it) }.select { it.jointype == :JOIN_INNER }
            @conjuncts = (Tree.conjuncts(select.where_clause) + ons.flat_map { Tree.conjuncts(it.quals) })
                         .filter_map { sides(it) }
          end

          def joins
            @conjuncts.filter_map do |left, right|
              next unless left.is_a?(Array) && right.is_a?(Array) && left.first != right.first

              right.last == "id" ? join(left, right) : join(right, left)
            end
          end

          # Whether the query already filters qualifier.column = $param.
          def copied?(qualifier, column, param) = @conjuncts.include?([[qualifier, column], param])

          private

          def join(child_side, parent_side)
            return unless parent_side.last == "id"

            child, parent = [child_side, parent_side].map { Tree.plain_table_named(@select.from_clause, it.first) }
            return unless child && parent

            Join.new(query: self, child:, parent:, qualifier: child_side.first, child_column: child_side.last,
                     pairs: pairs(parent_side.first))
          end

          # [type filter, id filter] for each <p>_type and <p>_id the
          # parent is filtered on.
          def pairs(qualifier)
            filters = @conjuncts.filter_map do |column, param|
              Filter.new(column: column.last, param:) if column.first == qualifier && param.is_a?(Integer)
            end
            filters.select { it.column.end_with?("_type") }.flat_map do |type|
              id_column = "#{type.column.delete_suffix("_type")}_id"
              filters.select { it.column == id_column }.map { [type, it] }
            end
          end

          # A conjunct's two sides, column first, for an = between a
          # qualified column and a qualified column or a bare placeholder:
          # [qualifier, column] for a column and the number for a
          # placeholder. Otherwise nil.
          def sides(node)
            expr = equals(node)
            sides = [expr.lexpr, expr.rexpr].map { side(it) } if expr
            return unless sides&.all? && sides.any?(Array)

            sides.first.is_a?(Array) ? sides : sides.reverse
          end

          def equals(node)
            expr = node.a_expr if node.node == :a_expr
            expr if expr&.kind == :AEXPR_OP && expr.name.map { it.string&.sval } == ["="]
          end

          def side(node)
            case node.node
            when :column_ref then Tree.qualified(node.column_ref)
            when :param_ref then node.param_ref.number
            end
          end
        end
      end
    end
  end
end
