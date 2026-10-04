# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctJoinToExists
        # What each column of a query reads, given the Tree::Items of its
        # FROM, all plain tables, and the Catalog that lists their columns.
        # Postgres finds a column the same way: name.column is that item's
        # column, and a bare column is the column of the one item that has
        # it. With none, or more than one, it's refused here.
        Columns = Data.define(:items, :catalog) do
          # [name, column] for the column ref reads, [name, :star] for a
          # name.*, and nil for a ref this can't resolve: a bare *, three
          # parts or more, a name no item has, a column its item hasn't
          # (which may be a function call, f(t), written t.f), or a bare
          # column that no item has, or that more than one has.
          def resolve(ref)
            fields = ref.fields.map { it.node == :string ? it.string.sval : it.node }
            case ref.fields.map(&:node)
            when %i[string string] then qualified(*fields)
            when %i[string a_star] then [fields.first, :star] if item(fields.first)
            when %i[string] then owner(fields.first)
            end
          end

          # What every column in nodes reads, as resolve gives it, or nil if
          # one can't be resolved.
          def reads(nodes)
            refs = Tree.find(nodes, PgQuery::ColumnRef).map { resolve(it) }
            refs if refs.all?
          end

          private

          def item(name) = items.find { it.name == name }

          def qualified(name, column) = ([name, column] if own?(item(name), column))

          def own?(item, column)
            item && catalog.column_names(item.table.schemaname, item.table.relname).include?(column)
          end

          def owner(column)
            owners = items.select { own?(it, column) }
            [owners.first.name, column] if owners.size == 1
          end
        end
      end
    end
  end
end
