# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctJoinToExists
        # A SELECT DISTINCT the rule can read: kept is the Tree::Item of
        # the table its select list reads, others those of its other
        # tables, conditions every condition of its WHERE and its joins'
        # ONs, selected the kept table's columns in the select list, in
        # order, with :star for a star, sorted its columns the ORDER BY
        # names, and limited whether there's a LIMIT or OFFSET.
        #
        # Query.read gives it, or nil for a FROM, select list, ORDER BY, or
        # condition the rule refuses (see DistinctJoinToExists).
        Query = Data.define(:kept, :others, :conditions, :selected, :sorted, :limited) do
          def self.read(select)
            items, conditions = from(select)
            selected = selected(select)
            sorted = sorted(select)
            kept = kept(items, selected + sorted) if items && selected && sorted
            return unless kept

            new(kept:, others: items - [kept], conditions:, selected: selected.map(&:last), sorted: sorted.map(&:last),
                limited: limited?(select))
          end

          # The FROM's items and every condition, if it's two or more
          # tables whose conditions can all be moved.
          def self.from(select)
            items = Tree.from_items(select.from_clause)
            ons = Tree.inner_conditions(select.from_clause)
            return unless ons && items.size > 1 && Tree.tables?(items) && Tree.find(select, PgQuery::SubLink).empty?

            conditions = ons + Tree.conjuncts(select.where_clause)
            [items, conditions] if (qualifiers(conditions) - items.map(&:name)).empty?
          end

          # The item that every one of columns, each a [name, column], reads.
          def self.kept(items, columns)
            names = columns.map(&:first).uniq
            items.find { it.name == names.first } if names.size == 1
          end

          def self.limited?(select) = !(select.limit_count.nil? && select.limit_offset.nil?)

          # [name, column], or [name, :star], for each select-list item, or
          # nil if one is anything else.
          def self.selected(select)
            columns = select.target_list.map { column(it.res_target.val.column_ref) }
            columns if columns.all?
          end

          # nil for a ref that's nil, which is what a node that isn't a
          # column gives.
          def self.column(ref)
            return unless ref

            name, star = ref.fields
            return Tree.qualified(ref) unless ref.fields.size == 2 && name.node == :string && star.node == :a_star

            [name.string.sval, :star]
          end

          # [name, column] for each ORDER BY item that isn't a position in
          # the select list, or nil if one is anything else. A constant
          # there is a position: Postgres takes no other.
          def self.sorted(select)
            columns = select.sort_clause.map { sort_column(it.sort_by.node) }
            columns.reject(&:empty?) if columns.all?
          end

          def self.sort_column(node)
            case node.node
            when :column_ref then Tree.qualified(node.column_ref)
            when :a_const then []
            end
          end

          # The name each column in nodes is qualified by, nil for a column
          # that isn't written name.column.
          def self.qualifiers(nodes)
            Tree.find(nodes, PgQuery::ColumnRef).map { Tree.qualified(it)&.first }.uniq
          end

          # The first selected column the catalog proves unique and not
          # null, or nil. With a LIMIT or OFFSET, it must be sorted by too.
          def key(catalog)
            table = kept.table
            columns = selected.flat_map { it == :star ? catalog.column_names(table.schemaname, table.relname) : [it] }.uniq
            columns &= sorted if limited
            columns.find { |column| assumptions(column).all? { catalog.met?(it) } }
          end

          def assumptions(key)
            table = "#{kept.table.schemaname}.#{kept.table.relname}"
            [{ "kind" => "unique", "table" => table, "columns" => [key] },
             { "kind" => "not_null", "table" => table, "column" => key }]
          end

          # Makes select the kept table alone, with no DISTINCT: the
          # conditions on it alone, then an EXISTS on the other tables with
          # the rest.
          def rewrite!(select)
            moved, stay = conditions.partition { reads_other?(it) }
            select.distinct_clause.clear
            select.from_clause.replace([range(kept)])
            select.where_clause = Tree.all_of(stay + [exists(moved)])
          end

          private

          def reads_other?(condition) = (self.class.qualifiers([condition]) - [kept.name]).any?

          def exists(moved)
            link = Tree.exists
            inner = link.sub_link.subselect.select_stmt
            others.each { inner.from_clause << range(it) }
            where = Tree.all_of(moved)
            inner.where_clause = where if where
            link
          end

          def range(item) = PgQuery::Node.new(range_var: item.table)
        end
      end
    end
  end
end
