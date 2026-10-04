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

          # The subquery's selected value, its columns qualified, and their
          # tables renamed where the original's FROM has their names, or
          # nil if it can't be. It changes sub in place. A value with a
          # subquery is refused, since a bare name in that would see the
          # original's FROM before the subquery's. So is a bare placeholder,
          # which IN would read as text and = as x's type.
          def selected(sub, from, tree, catalog)
            node = sub.target_list.first.res_target.val
            columns = movable(node, sub, catalog)
            names = Tree.from_items(from).map(&:name)
            return unless columns && !names.include?(nil)

            clashes = columns.map { Tree.qualified(it).first }.uniq & names
            node if clashes.all? { rename!(sub, it, tree) }
          end

          # The columns of node, each qualified, or nil if node can't move.
          def movable(node, sub, catalog)
            return if node.node == :param_ref || Tree.find(node, PgQuery::SubLink).any?

            columns = Tree.find(node, PgQuery::ColumnRef)
            columns if columns.all? { qualify!(it, sub, catalog) }
          end

          # The column as name.column, or nil: it was, or it was a bare
          # column of the subquery's one table, or of just one of its plain
          # tables, by the catalog.
          def qualify!(column, sub, catalog)
            fields = column.fields
            return unless fields.all? { it.node == :string } && fields.size.between?(1, 2)
            return column if fields.size == 2

            return unless (table = sole_table(sub) || owner(fields.first.string.sval, sub, catalog))

            fields.unshift(PgQuery::Node.new(string: PgQuery::String.new(sval: Tree.refname(table))))
            column
          end

          def sole_table(sub)
            sub.from_clause.first.range_var if sub.from_clause.size == 1 && sub.from_clause.first.node == :range_var
          end

          # The one plain table of sub's FROM with a column named name, or
          # nil.
          def owner(name, sub, catalog)
            items = Tree.from_items(sub.from_clause)
            return unless Tree.tables?(items)

            owners = items.map(&:table).select { catalog.column_names(it.schemaname, it.relname).include?(name) }
            owners.first if owners.one?
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
