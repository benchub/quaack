# frozen_string_literal: true

require "pg_query"
require_relative "../tree"
require_relative "../distinct_key_removal/keys"

module Quaack
  module Enclave
    module RewriteRules
      class UnionToUnionAll
        # One column an arm outputs: column, the name of its table's column
        # when the item is that column written name.column or bare, or nil;
        # and node, the item's expression, or nil for a column a star stands
        # for.
        Output = Data.define(:column, :node)

        # One SELECT a UNION is made of: table, the RangeVar of the one plain
        # table it reads, and outputs, an Output for each column it outputs,
        # with each star written out from the catalog.
        #
        # Arm.read gives one, or nil unless the SELECT has no DISTINCT and
        # no GROUP BY, whose grouping sets can repeat a key as NULL. Its FROM
        # is one schema-qualified table, read whole, with no column aliases
        # (Tree.plain_table?), so the table can't be a CTE, and the SELECT
        # isn't a VALUES list. Its WHERE, ORDER BY, LIMIT, and OFFSET only
        # drop rows, so they may stay. Its select list and ORDER BY call no
        # function or operator that could return a set or be an aggregate or
        # a window function, even in a subquery (Catalog#row_wise?). A
        # set-returning call gives several rows for one row of the table. A
        # window function, or an aggregate in a subquery, gives one, but v1
        # refuses them too, as distinct_key_removal does. With no GROUP BY,
        # an aggregate or a HAVING makes the arm one group, and Postgres then
        # refuses the key's bare column, so those need no check of their own.
        #
        # A bare column names the table's column of that name, if it has
        # one, since Postgres looks in the arm's own FROM before any outer
        # query's. A name the table lacks is never one of its keys' columns.
        Arm = Data.define(:table, :outputs) do
          def self.read(select, catalog)
            table = table(select) if plain?(select)
            return unless table && catalog.row_wise?(nodes(select))

            new(table:, outputs: outputs(select, table, catalog))
          end

          def self.plain?(select) = select.distinct_clause.empty? && select.group_clause.empty?

          def self.table(select)
            from = select.from_clause
            table = from.first.range_var if from.size == 1 && from.first.node == :range_var
            table if table && Tree.plain_table?(table)
          end

          def self.nodes(select)
            select.target_list.map { it.res_target.val } + select.sort_clause.map { it.sort_by.node }
          end

          # Each target's Outputs.
          def self.outputs(select, table, catalog)
            name = Tree.refname(table)
            select.target_list.flat_map do |target|
              node = target.res_target.val
              fields = DistinctKeyRemoval::Keys.fields(node)
              next star(table, catalog) if [[:a_star], [name, :a_star]].include?(fields)

              [Output.new(column: column(fields, name), node:)]
            end
          end

          def self.star(table, catalog)
            catalog.column_names(table.schemaname, table.relname).map { Output.new(column: it, node: nil) }
          end

          # The column that fields, a column reference's, name: one written
          # bare, or name.column. nil for any other.
          def self.column(fields, name)
            fields = fields.drop(1) if fields&.size == 2 && fields.first == name
            fields.first if fields&.size == 1 && fields.first.is_a?(String)
          end
        end
      end
    end
  end
end
