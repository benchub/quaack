# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class OrToUnion
        # What a SELECT needs of its FROM tables once a UNION stands in
        # for them. columns is the UNION's select list, each as
        # [name, column], where name is what the query reads the table by:
        # every column the query uses outside its WHERE, then a key of
        # every table. stars maps each name the select list has as name.*
        # to that table's columns, and assumptions states each key unique
        # and not null.
        #
        # Reads.of gives nil unless all of this holds:
        #
        # - The FROM holds only tables, each schema-qualified (so not a
        #   CTE), read without ONLY and without column aliases, under a
        #   name of its own, joined only by plain inner or cross joins: no
        #   outer join, NATURAL, USING, or join alias.
        # - Every table has a key: columns the catalog proves unique
        #   together and each not null, each of a type UNION compares (see
        #   Catalog#columns). A key of one column is used first; see key.
        # - Outside the WHERE, every column is written name.column or, as
        #   a whole select-list entry, name.*, where name is one of the
        #   tables. Each is a column the catalog lists, so not a system
        #   column, of a type UNION compares.
        Reads = Data.define(:columns, :stars, :assumptions) do
          def self.of(select, catalog)
            items = tables(select.from_clause)
            return unless items

            tables = items.to_h { [it.name, columns(it, catalog)] }
            keys = items.map { key(it, catalog) }
            stars = stars(select, tables)
            used = used(select, tables, stars)
            with_keys(used, keys, stars) if keys.all? && used
          end

          def self.with_keys(used, keys, stars)
            new(columns: (used + keys.flat_map(&:first)).uniq, stars:, assumptions: keys.flat_map(&:last).uniq)
          end

          def self.columns(item, catalog) = catalog.columns(item.table.schemaname, item.table.relname)

          # The FROM's Tree::Items, if it holds only tables Reads takes.
          def self.tables(from)
            items = Tree.from_items(from)
            items if !items.empty? && Tree.inner_conditions(from) && Tree.tables?(items)
          end

          # [[[name, column], ...], their assumptions] for the table's key,
          # or nil. A key of one column comes first, the first in the
          # table's order; then the catalog's keys of several columns
          # (Catalog#keys), the fewest columns first, then the index made
          # first.
          def self.key(item, catalog)
            table = "#{item.table.schemaname}.#{item.table.relname}"
            candidates(item, catalog).each do |key|
              facts = [{ "kind" => "unique", "table" => table, "columns" => key },
                       *key.map { { "kind" => "not_null", "table" => table, "column" => it } }]
              return [key.map { [item.name, it] }, facts] if facts.all? { catalog.met?(it) }
            end
            nil
          end

          # The column sets that may be the table's key, each of columns
          # UNION compares, best first, and each column once: an index on
          # (a, b, a) is a key (a, b).
          def self.candidates(item, catalog)
            comparable = columns(item, catalog).select(&:comparable).map(&:name)
            several = catalog.keys(item.table.schemaname, item.table.relname)
                             .map(&:uniq).select { it.size > 1 && (it - comparable).empty? }
            comparable.map { [it] } + by_size(several)
          end

          # Keys by their number of columns, then in their order.
          def self.by_size(keys) = keys.sort_by.with_index { |key, i| [key.size, i] }

          # The name of a select-list entry that is name.*, or nil.
          def self.star(target)
            fields = target.val.column_ref.fields if target.val&.node == :column_ref
            fields.first.string.sval if fields&.map(&:node) == %i[string a_star]
          end

          def self.stars(select, tables)
            select.target_list.filter_map { star(it.res_target) }.uniq.to_h { [it, tables.fetch(it, []).map(&:name)] }
          end

          # Everything outside the FROM and the WHERE, but for the name.*
          # entries: the nodes whose columns the UNION must give.
          def self.outside(select)
            [*select.target_list.reject { star(it.res_target) }, *select.sort_clause, select.limit_count,
             select.limit_offset].compact
          end

          # Every [name, column] the query uses outside its WHERE, or nil
          # if one of them isn't a column the UNION can give.
          def self.used(select, tables, stars)
            written = Tree.find(outside(select), PgQuery::ColumnRef).map { Tree.qualified(it) }
            used = stars.flat_map { |name, columns| columns.map { [name, it] } } + written
            used.uniq if written.all? && used.all? { comparable?(tables, *it) }
          end

          def self.comparable?(tables, name, column)
            tables.fetch(name, []).any? { it.name == column && it.comparable }
          end
        end
      end
    end
  end
end
