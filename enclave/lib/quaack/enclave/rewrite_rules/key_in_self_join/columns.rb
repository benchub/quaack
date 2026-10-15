# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class KeyInSelfJoin
        # Reads a column of a FROM's Items (see Tree::Item) as [name,
        # column]. name.column is read as written. A bare column is read as
        # Postgres reads it: as the column of the one Item whose table has a
        # column of that name, by the catalog. resolve gives nil for a bare
        # column unless every Item is a plain table under a name of its own
        # (see Tree.tables?), whose columns the catalog then knows, and
        # exactly one of them has the column. With none, Postgres would read
        # it as an enclosing query's column, or a whole row; with two, it's
        # an error.
        Columns = Data.define(:items, :catalog) do
          def resolve(ref)
            qualified = Tree.qualified(ref)
            return qualified if qualified

            column = Tree.bare_name(ref)
            return unless column && Tree.tables?(items)

            owners = items.select { columns_of(it.table).include?(column) }
            [owners.first.name, column] if owners.size == 1
          end

          private

          def columns_of(table) = catalog.column_names(table.schemaname, table.relname)
        end
      end
    end
  end
end
