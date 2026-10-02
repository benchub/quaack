# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"
require_relative "reads"

module Quaack
  module Enclave
    module RewriteRules
      class OrToUnion
        # Builds the rewrite: a copy of the original tree whose SELECT
        # reads, in place of its tables, the UNION of one branch per arm of
        # the OR that is the WHERE's index-th condition.
        #
        #   Union.new(parse.tree, index, reads).tree
        #
        # A branch is the query's FROM and WHERE with one arm in the OR's
        # place, selecting reads.columns, each under an alias of its own.
        # It has no DISTINCT, ORDER BY, LIMIT, or OFFSET: those stay
        # outside. Outside, each column is renamed to the UNION's, each
        # name.* becomes the table's columns, and a select-list entry that
        # was only a column gets that column's name, which the renaming
        # would otherwise change. The original is never changed.
        class Union
          def initialize(original, index, reads)
            @original = original
            @index = index
            @reads = reads
            names = Tree::Names.new(original)
            @aliases = reads.columns.to_h { [it, names.fresh(it.last)] }
            @name = names.fresh("arms")
          end

          def tree
            tree = Deparse.copy(@original)
            select = Tree.select(tree)
            rename!(select)
            select.from_clause.replace([subselect])
            select.where_clause = nil
            tree
          end

          private

          def subselect
            arms = Tree.conjuncts(Tree.select(@original).where_clause)[@index].bool_expr.args.size
            union = Array.new(arms) { branch(it) }.reduce { |left, right| union(left, right) }
            PgQuery::Node.new(range_subselect: PgQuery::RangeSubselect.new(
              subquery: PgQuery::Node.new(select_stmt: union), alias: PgQuery::Alias.new(aliasname: @name)
            ))
          end

          def union(left, right)
            PgQuery::SelectStmt.new(op: :SETOP_UNION, larg: left, rarg: right, limit_option: :LIMIT_OPTION_DEFAULT)
          end

          def branch(arm)
            select = Tree.select(Deparse.copy(@original))
            select.where_clause = where(select, arm)
            select.target_list.replace(@aliases.map { |(table, column), as| target(column(table, column), as) })
            unlimit!(select)
            select
          end

          # The WHERE with only one arm in the OR's place.
          def where(select, arm)
            conditions = Tree.conjuncts(select.where_clause)
            conditions[@index, 1] = Tree.conjuncts(conditions[@index].bool_expr.args[arm])
            Tree.all_of(conditions)
          end

          def unlimit!(select)
            [select.sort_clause, select.distinct_clause].each(&:clear)
            select.limit_count = select.limit_offset = nil
            select.limit_option = :LIMIT_OPTION_DEFAULT
          end

          # Makes everything outside the WHERE read the UNION's columns.
          def rename!(select)
            select.target_list.each { label!(it.res_target) }
            Tree.find(Reads.outside(select), PgQuery::ColumnRef).each { point!(it) }
            select.target_list.replace(select.target_list.flat_map { expanded(it) })
          end

          def point!(column_ref)
            column_ref.fields.replace([string(@name), string(@aliases.fetch(Tree.qualified(column_ref)))])
          end

          def label!(target)
            column = Tree.qualified(target.val.column_ref) if target.val.node == :column_ref
            target.name = column.last if column && target.name.empty?
          end

          # The select-list entry itself, or for name.*, an entry for each
          # of the table's columns.
          def expanded(target)
            star = Reads.star(target.res_target)
            return [target] unless star

            @reads.stars.fetch(star).map { target(column(@name, @aliases.fetch([star, it])), it) }
          end

          def target(val, name) = PgQuery::Node.new(res_target: PgQuery::ResTarget.new(name:, val:))

          def column(table, column)
            PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: [string(table), string(column)]))
          end

          def string(sval) = PgQuery::Node.new(string: PgQuery::String.new(sval:))
        end
      end
    end
  end
end
