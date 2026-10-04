# frozen_string_literal: true

require "pg_query"
require_relative "../../implicit_name"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class UnionOuterFilterRemoval
        # One column a UNION arm outputs: its ColumnRef Node when it's a
        # column written as name.column, or nil; its name; and, for a
        # column of a plain table, the column's Catalog::Info. Only a
        # column's name matters, and ImplicitName gives a column's the way
        # Postgres does.
        Output = Data.define(:column, :name, :info)

        # One SELECT a UNION is made of. hidden lists the CTE names a WITH
        # between it and the outer query defines, its own included, which
        # hide the outer query's CTEs of those names from its WHERE.
        # outputs is nil when it can't be read: a GROUP BY with grouping
        # sets, whose rows can hold NULLs no row had, or a star this can't
        # expand. A VALUES list has none, and no WHERE.
        class Arm
          attr_reader :select, :hidden, :outputs

          def initialize(select, hidden, catalog)
            @select = select
            @hidden = hidden
            @outputs = Outputs.of(select, catalog) unless grouping_sets?
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
            name = target.name.empty? ? ImplicitName.of(target.val) : target.name
            Output.new(column: (target.val if qualified), name:, info: (info(*qualified, items, catalog) if qualified))
          end

          def star(ref, items, catalog)
            item = starred(ref.fields, items)
            table = item&.table
            return unless table

            names = catalog.column_names(table.schemaname, table.relname)
            names.map { Output.new(column: column(item.name, it), name: it, info: info(item.name, it, items, catalog)) }
                 .then { it unless it.empty? }
          end

          def starred(fields, items)
            return items.first if fields.size == 1 && items.size == 1

            named(items, fields.first.string.sval) if fields.size == 2
          end

          def info(qualifier, name, items, catalog)
            table = named(items, qualifier)&.table
            catalog.column_info(table.schemaname, table.relname, name) if table && Tree.plain_table?(table)
          end

          # Postgres refuses two FROM items of one name.
          def named(items, name) = items.find { it.name == name }

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
          # aliases, and never on an outer join's nullable side. Postgres
          # refuses two FROM items of one name.
          def self.all(top, catalog)
            top.from_clause.flat_map { kept(it) }.filter_map do |sub|
              union = build(sub.subquery.select_stmt, catalog) if plain?(sub)
              [sub.alias.aliasname, union] if union
            end.to_h
          end

          def self.plain?(sub) = sub.alias && !sub.lateral && sub.alias.colnames.empty?

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
            return unless select.op == :SETOP_UNION

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
          # isn't exactly one column's. Postgres refuses a name that's
          # ambiguous, so a column whose name is unknown isn't this one.
          def position(name)
            names = arms.first.outputs.map(&:name)
            index = names.index(name)
            index if names.count(name) == 1 && typed?(index)
          end

          def typed?(index)
            outputs = arms.map { it.outputs[index] }
            outputs.all? { it&.info } && outputs.map(&:info).uniq.size == 1
          end
        end
      end
    end
  end
end
