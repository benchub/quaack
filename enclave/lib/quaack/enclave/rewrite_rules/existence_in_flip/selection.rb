# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ExistenceInFlip
        # y, the subquery's selected value, made safe to move inside the
        # EXISTS, where the original's FROM is nearer than the subquery's.
        module Selection
          module_function

          # The subquery's selected column, qualified, with its table
          # renamed if the original's FROM has its name, or nil if it can't
          # be. It changes sub in place.
          def selected(sub, from, tree)
            node = sub.target_list.first.res_target.val
            column = qualify!(node.column_ref, sub)
            names = Tree.from_items(from).map(&:name)
            return unless column && !names.include?(nil)

            name = Tree.qualified(column).first
            node if !names.include?(name) || rename!(sub, name, tree)
          end

          # The column as name.column, or nil: it was, or it was a bare
          # column of the subquery's one table.
          def qualify!(column, sub)
            fields = column.fields
            return unless fields.all? { it.node == :string } && fields.size.between?(1, 2)
            return column if fields.size == 2

            return unless (table = sole_table(sub))

            fields.unshift(PgQuery::Node.new(string: PgQuery::String.new(sval: Tree.refname(table))))
            column
          end

          def sole_table(sub)
            sub.from_clause.first.range_var if sub.from_clause.size == 1 && sub.from_clause.first.node == :range_var
          end

          # Gives the subquery's table under name a fresh alias, renames
          # every column the subquery reads as name.something, and returns
          # the alias. Refuses, with nil, when a subquery inside could have
          # a name of its own that's the same.
          def rename!(sub, name, tree)
            table = renamable(sub, name)
            return unless table

            fresh = Tree::Names.new(tree).fresh(name)
            Tree.find(sub, PgQuery::ColumnRef).each { rename_column!(it, name, fresh) }
            table.alias ? table.alias.aliasname = fresh : table.alias = PgQuery::Alias.new(aliasname: fresh)
            fresh
          end

          def renamable(sub, name)
            table = Tree.from_items(sub.from_clause).find { it.name == name }&.table
            table if [PgQuery::SubLink, PgQuery::RangeSubselect].all? { Tree.find(sub, it).empty? }
          end

          def rename_column!(column, name, fresh)
            Tree.qualify!(column, fresh) if column.fields.size > 1 && column.fields.first.string&.sval == name
          end
        end
      end
    end
  end
end
