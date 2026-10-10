# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class SharedScanCte
        # A GROUP BY that relies on a copy's primary key: it names the key
        # and nothing else of the copy's columns, and the select list, HAVING,
        # or ORDER BY reads the rest. Postgres lets that stand for the
        # columns, but a CTE has no primary key, so it wouldn't prepare the
        # rewrite.
        #
        # This adds the columns the query reads to the GROUP BY, for each
        # copy whose whole key it names. The key is unique in the table (the
        # catalog says nothing else, see Catalog#primary_key), so every row
        # of a group has the same copy row, and so the same value in each of
        # that copy's columns. Grouping by one more of them splits no group,
        # and the groups, and what each reads, don't change. A GROUP BY that
        # doesn't name the whole key gets nothing: a column it only groups
        # as part of an expression, such as lower(name), would split the
        # groups if it were added by itself. Grouping sets get nothing too,
        # since each set would have to be reasoned about on its own.
        module Grouping
          private

          # Adds to top's GROUP BY, for each of copies, the columns it needs.
          def group_by_columns!(top, copies, table, catalog)
            return if top.group_clause.empty? || top.group_clause.any? { it.node == :grouping_set }

            grouped = top.group_clause.filter_map { column(it) }
            copies.each { add_columns!(top, it.name, table.first(2), catalog, grouped) }
          end

          def add_columns!(top, name, table, catalog, grouped)
            key = catalog.primary_key(*table)
            return unless key.any? && key.all? { grouped.include?([name, it]) }

            missing(top, name, table, catalog, grouped).each do |column|
              top.group_clause << column_node(name, column)
              grouped << [name, column]
            end
          end

          # [qualifier, column] for a group item that's exactly that.
          def column(node) = node.node == :column_ref ? Tree.qualified(node.column_ref) : nil

          # The columns of copy that the query reads outside its GROUP BY,
          # WHERE, and FROM, in the order it reads them, that the GROUP BY
          # doesn't name.
          def missing(top, name, table, catalog, grouped)
            reads = [*top.target_list, top.having_clause, *top.sort_clause, *top.window_clause, *top.distinct_clause]
            refs = Tree.find(reads.compact, PgQuery::ColumnRef).filter_map { read_columns(it, name, table, catalog) }
            refs.flatten.uniq.reject { grouped.include?([name, it]) }
          end

          # The copy's columns a column reference reads: the one it names,
          # all of them for copy.*, and none if it reads another name.
          def read_columns(ref, name, table, catalog)
            return unless ref.fields.first.string&.sval == name && ref.fields.size == 2

            last = ref.fields.last
            last.node == :a_star ? catalog.column_names(*table) : [last.string.sval]
          end

          def column_node(qualifier, name)
            strings = [qualifier, name].map { PgQuery::Node.new(string: PgQuery::String.new(sval: it)) }
            PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(fields: strings))
          end
        end
      end
    end
  end
end
