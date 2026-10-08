# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class NotInToNotExists
        # A SELECT of the subquery's FROM items under the name of an outer
        # table NOT IN tests, which would hide the outer row from the
        # correlation, as an ORM that never aliases a table writes. Each
        # gets an alias no name in the query uses, and every column of it
        # is renamed.
        module Shadows
          module_function

          # Whether the correlation can read the outer row: nothing in
          # sub's FROM has an outer table's name, or each that has is a
          # table that can be given another alias. That needs every column
          # sub reads written name.column, and no deeper scope to hide a
          # name.
          def correlatable?(tested, sub)
            shadows = shadows(tested, sub)
            return true if shadows.empty?

            shadows.none? { it.table.nil? } && columns(sub).all? { Tree.qualified(it) } &&
              [PgQuery::SubLink, PgQuery::RangeSubselect].all? { Tree.find(sub, it).empty? }
          end

          # Gives each of sub's FROM items under an outer table's name a
          # fresh alias, and renames its columns.
          def unshadow!(tested, sub, names)
            shadows = shadows(tested, sub)
            return if shadows.empty?

            renames = shadows.to_h { [it.name, names.fresh(it.name)] }
            rename!(columns(sub), renames)
            shadows.each { realias!(it.table, renames[it.name]) }
          end

          def shadows(tested, sub)
            outer = tested.map { Tree.qualified(it).first }
            Tree.from_items(sub.from_clause).select { outer.include?(it.name) }
          end

          # Requalifies each column whose name renames has a new name for.
          def rename!(columns, renames)
            columns.each do |column|
              fresh = renames[Tree.qualified(column).first]
              Tree.qualify!(column, fresh) if fresh
            end
          end

          # Every column sub reads.
          def columns(sub) = Tree.find(sub, PgQuery::ColumnRef)

          def realias!(range, name)
            range.alias ? range.alias.aliasname = name : range.alias = PgQuery::Alias.new(aliasname: name)
          end
        end
      end
    end
  end
end
