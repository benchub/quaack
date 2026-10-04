# frozen_string_literal: true

require "pg_query"
require_relative "../../implicit_name"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class UnionOuterFilterRemoval
        # One column a UNION arm outputs: its ColumnRef Node when it's a
        # column written as name.column, or nil; its name, or nil when it's
        # unknown; and, for a column of a plain table, the column's
        # Catalog::Info.
        Output = Data.define(:column, :name, :info)

        # One SELECT a UNION is made of. hidden lists the CTE names a WITH
        # between it and the outer query defines, its own included, which
        # hide the outer query's CTEs of those names from its WHERE.
        # outputs is nil when it can't be read: a VALUES list, a GROUP BY
        # with grouping sets, whose rows can hold NULLs no row had, or a
        # star this can't expand.
        class Arm
          attr_reader :select, :hidden, :outputs

          def initialize(select, hidden, catalog)
            @select = select
            @hidden = hidden
            @outputs = Outputs.of(select, catalog) if select.values_lists.empty? && !grouping_sets?
          end

          def grouping_sets?
            select.group_clause.any? { it.node == :grouping_set }
          end
        end

        # The columns a SELECT outputs, with each star expanded from the
        # catalog, or nil when a star's table isn't one plain table the
        # catalog has.
        module Outputs
          module_function

          def of(select, catalog)
            items = Tree.from_items(select.from_clause)
            select.target_list.each_with_object([]) do |target, outputs|
              found = target(target.res_target, items, catalog)
              return nil unless found

              outputs.concat(found)
            end
          end

          def target(target, items, catalog)
            ref = target.val.column_ref if target.val.node == :column_ref
            return star(ref, items, catalog) if ref && ref.fields.last.node == :a_star

            [output(target, ref, items, catalog)]
          end

          def output(target, ref, items, catalog)
            qualified = Tree.qualified(ref) if ref
            name = target.name.empty? ? implicit(target.val) : target.name
            Output.new(column: (target.val if qualified), name:, info: (info(*qualified, items, catalog) if qualified))
          end

          # ImplicitName names a subquery from its parse, which can differ
          # from Postgres, so its name is unknown.
          def implicit(node)
            ImplicitName.of(node) unless node.node == :sub_link
          end

          def star(ref, items, catalog)
            item = starred(ref.fields, items)
            table = item&.table
            return unless table && Tree.plain_table?(table)

            names = catalog.column_names(table.schemaname, table.relname)
            names.map { Output.new(column: column(item.name, it), name: it, info: info(item.name, it, items, catalog)) }
                 .then { it unless it.empty? }
          end

          def starred(fields, items)
            return items.first if fields.size == 1 && items.size == 1

            only(items, fields.first.string.sval) if fields.size == 2 && fields.first.node == :string
          end

          def info(qualifier, name, items, catalog)
            table = only(items, qualifier)&.table
            catalog.column_info(table.schemaname, table.relname, name) if table && Tree.plain_table?(table)
          end

          def only(items, name)
            named = items.select { it.name == name }
            named.first if named.size == 1
          end

          def column(qualifier, name)
            fields = [qualifier, name].map { PgQuery::Node.new(string: PgQuery::String.new(sval: it)) }
            PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields:))
          end
        end

        # A UNION or UNION ALL subquery in the outer query's FROM, and its
        # arms, a nested UNION's included.
        class Union
          attr_reader :arms

          # The Unions of the top-level SELECT's FROM, by alias: each a
          # subquery under its own name, not LATERAL, with no column
          # aliases, and never on an outer join's nullable side.
          def self.all(top, catalog)
            items = Tree.from_items(top.from_clause)
            return {} if items.any? { it.name.nil? }

            top.from_clause.flat_map { kept(it) }.filter_map do |sub|
              union = build(sub.subquery.select_stmt, catalog) if plain?(sub, items)
              [sub.alias.aliasname, union] if union
            end.to_h
          end

          def self.plain?(sub, items)
            sub.alias && !sub.lateral && sub.alias.colnames.empty? && items.one? { it.name == sub.alias.aliasname }
          end

          # The subqueries of a FROM item that an outer join never fills
          # with NULLs.
          def self.kept(node)
            return [node.range_subselect] if node.node == :range_subselect
            return [] unless node.node == :join_expr

            join = node.join_expr
            left, right = Tree::NULLABLE[join.jointype]
            [*(kept(join.larg) if left == false), *(kept(join.rarg) if right == false)]
          end

          def self.build(select, catalog)
            return unless select&.op == :SETOP_UNION

            arms = arms(select, [], catalog)
            new(arms) if arms&.all?(&:outputs)
          end

          # Every arm under select, or nil if a set operation in it isn't a
          # UNION.
          def self.arms(select, hidden, catalog)
            hidden += select.with_clause.ctes.map { it.common_table_expr.ctename } if select.with_clause
            case select.op
            when :SETOP_NONE then [Arm.new(select, hidden, catalog)]
            when :SETOP_UNION
              left = arms(select.larg, hidden, catalog)
              right = arms(select.rarg, hidden, catalog) if left
              left + right if right
            end
          end

          def initialize(arms)
            @arms = arms
          end

          # The position of the column the outer query calls name, when
          # every arm outputs a plain table's column there, all of one type
          # and collation, so UNION casts none of them. nil if the name
          # isn't exactly one column's, or a column's name is unknown.
          def position(name)
            names = arms.first.outputs.map(&:name)
            index = names.index(name)
            index if !names.include?(nil) && names.count(name) == 1 && typed?(index)
          end

          def typed?(index)
            outputs = arms.map { it.outputs[index] }
            outputs.all? { it&.column && it.info } && outputs.map(&:info).uniq.size == 1
          end
        end
      end
    end
  end
end
