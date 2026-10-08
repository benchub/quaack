# frozen_string_literal: true

require "pg_query"
require_relative "../tree"
require_relative "columns"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctJoinToExists
        # A SELECT DISTINCT the rule can read: kept is the Tree::Item of
        # the table its select list and ORDER BY read, others those of its
        # other tables, conditions every condition of its WHERE and its
        # joins' ONs, each with the names of the items it reads, selected
        # the kept table's columns the select list holds bare, in order,
        # with :star for a star, sorted the columns the ORDER BY holds bare
        # as name.column, limited whether there's a LIMIT or OFFSET, and
        # shown the select list's and ORDER BY's expressions.
        #
        # Query.read gives it, or nil for a FROM, select list, ORDER BY, or
        # condition the rule refuses (see DistinctJoinToExists).
        Query = Data.define(:kept, :others, :conditions, :selected, :sorted, :limited, :shown) do
          def self.read(select, catalog)
            items, conditions = from(select)
            return unless items

            columns = Columns.new(items:, catalog:)
            conditions = conditions.map { [it, condition_reads(columns, it)] }
            shown = shown(select)
            kept = kept(items, columns.reads(shown)) if conditions.all?(&:last)
            return unless kept && kept_alone?(conditions, kept)

            new(kept:, others: items - [kept], conditions:, selected: selected(select, columns), sorted: sorted(select),
                limited: limited?(select), shown:)
          end

          def self.shown(select)
            select.target_list.map { it.res_target.val } + select.sort_clause.map { it.sort_by.node }
          end

          # The FROM's items and every condition, if it's two or more
          # tables and no subquery is in the select list, ORDER BY, LIMIT,
          # or OFFSET.
          def self.from(select)
            items = Tree.from_items(select.from_clause)
            ons = Tree.inner_conditions(select.from_clause)
            outside = [*shown(select), select.limit_count, select.limit_offset].compact
            return unless ons && items.size > 1 && Tree.tables?(items) && Tree.find(outside, PgQuery::SubLink).empty?

            [items, ons + Tree.conjuncts(select.where_clause)]
          end

          # Whether each of conditions, with the names of the items it
          # reads, has no subquery or reads no item but kept. One that reads
          # another table would go into the EXISTS, and the rule leaves
          # those alone.
          def self.kept_alone?(conditions, kept)
            conditions.all? do |condition, names|
              Tree.find(condition, PgQuery::SubLink).empty? || (names - [kept.name]).empty?
            end
          end

          # The names of the items condition reads, or nil if it has a
          # column that can't be resolved, or a name.*.
          def self.condition_reads(columns, condition)
            reads = columns.reads([condition])
            reads.map(&:first).uniq if reads&.none? { it.last == :star }
          end

          # The item that every one of reads, each a [name, column], reads,
          # if they're all of one.
          def self.kept(items, reads)
            names = reads&.map(&:first)&.uniq
            items.find { it.name == names.first } if names&.size == 1
          end

          def self.limited?(select) = !(select.limit_count.nil? && select.limit_offset.nil?)

          # The column, or :star, for each select-list item that's only a
          # column of the kept table, which is every column it reads.
          def self.selected(select, columns)
            select.target_list.filter_map { (ref = it.res_target.val.column_ref) && columns.resolve(ref).last }
          end

          # The column of each ORDER BY item written name.column. A bare
          # name there may be an output column's, as in ORDER BY x for
          # SELECT a.title AS x, so it isn't taken as the column of that
          # name.
          def self.sorted(select)
            select.sort_clause.filter_map { (ref = it.sort_by.node.column_ref) && Tree.qualified(ref)&.last }
          end

          # The kept table's column names, which its star stands for.
          def star(catalog) = catalog.column_names(kept.table.schemaname, kept.table.relname)

          # The columns of a key the catalog proves unique and not null,
          # every one of them selected, or nil. With a LIMIT or OFFSET, they
          # must all be sorted by too. One read of the table's indexes gives
          # the candidates (Catalog#keys). The fewest columns win, then the
          # one whose last column comes first in the select list, then the
          # index made first.
          def key(catalog)
            columns = selected.flat_map { it == :star ? star(catalog) : [it] }.uniq
            columns &= sorted if limited
            candidates(catalog, columns).find { |key| assumptions(key).all? { catalog.met?(it) } }
          end

          # The catalog's candidate keys made of columns alone, best first.
          def candidates(catalog, columns)
            keys = catalog.keys(kept.table.schemaname, kept.table.relname).select { (it - columns).empty? }
            keys.sort_by.with_index { |key, i| [key.size, key.map { columns.index(it) }.max, i] }
          end

          def assumptions(key)
            table = "#{kept.table.schemaname}.#{kept.table.relname}"
            [{ "kind" => "unique", "table" => table, "columns" => key },
             *key.map { { "kind" => "not_null", "table" => table, "column" => it } }]
          end

          # Makes select the kept table alone, with no DISTINCT: the
          # conditions on it alone, then an EXISTS on the other tables with
          # the rest.
          def rewrite!(select)
            moved, stay = split
            select.distinct_clause.clear
            select.from_clause.replace([range(kept)])
            select.where_clause = Tree.all_of(stay + [exists(moved)])
          end

          private

          # The conditions that read another table, and those that don't.
          def split = conditions.partition { |_, names| (names - [kept.name]).any? }.map { |part| part.map(&:first) }

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
