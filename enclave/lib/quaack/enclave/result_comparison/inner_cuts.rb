# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparison
      # A LIMIT or OFFSET below the top level, in a subquery, a CTE, or a
      # set operation's arm, keeps whichever tied rows Postgres reaches
      # first, and the fixture shows only that pick. A candidate that keeps
      # the wrong rows can match by luck, and a right one can mismatch. So
      # fixture-compare refuses such a cut as unsupported_order unless it's
      # deterministic: its SELECT reads one table and nothing else, has no
      # GROUP BY, DISTINCT, or set operation, and its ORDER BY names, as
      # plain columns, every column of a not-null unique key with no
      # predicate or expression. Its rows are then distinct table rows in a
      # total order, so the cut keeps the same rows however ties reach it.
      # An OFFSET 0 with no LIMIT cuts nothing.
      module InnerCuts
        # The table's key column sets: its primary key, and each immediate
        # unique index with no predicate or expression over not-null
        # columns. A table with inheritance children has none, since its
        # indexes don't cover them, unless it's partitioned. %<table>s is the
        # quoted name, in a string literal.
        KEYS_SQL = <<~SQL
          SELECT i.indexrelid::pg_catalog.int8, k.attname
          FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) i.indrelid
          JOIN pg_catalog.pg_attribute k ON k.attrelid OPERATOR(pg_catalog.=) i.indrelid
            AND k.attnum OPERATOR(pg_catalog.=) ANY (i.indkey::pg_catalog.int2[])
          WHERE i.indrelid OPERATOR(pg_catalog.=) pg_catalog.to_regclass('%<table>s')
            AND i.indisunique AND i.indimmediate AND i.indpred IS NULL AND i.indexprs IS NULL
            AND (NOT c.relhassubclass OR c.relkind OPERATOR(pg_catalog.=) 'p')
            AND NOT EXISTS (
              SELECT FROM pg_catalog.pg_attribute a
              WHERE a.attrelid OPERATOR(pg_catalog.=) i.indrelid
                AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey::pg_catalog.int2[]) AND NOT a.attnotnull)
        SQL

        module_function

        # Whether any of shapes (Shape) has a cut below its top level that
        # isn't deterministic.
        def refused?(transaction, shapes)
          shapes.map(&:tree).any? do |tree|
            ctes = cte_names(tree)
            inner_selects(tree).any? { |select| !deterministic?(transaction, select, ctes) }
          end
        end

        def cte_names(node)
          case node
          when Hash
            own = node[:common_table_expr] ? [node[:common_table_expr][:ctename]] : []
            own + node.values.flat_map { cte_names(it) }
          when Array then node.flat_map { cte_names(it) }
          else []
          end
        end

        def inner_selects(tree)
          top = tree[:stmts].first[:stmt][:select_stmt]
          selects(top.values).select { cut?(it) }
        end

        def selects(node)
          case node
          when Hash
            own = node[:select_stmt] ? [node[:select_stmt]] : []
            own + node.values.flat_map { selects(it) }
          when Array then node.flat_map { selects(it) }
          else []
          end
        end

        def cut?(select)
          return true if select[:limit_count]

          offset = select[:limit_offset]
          !offset.nil? && offset.dig(:a_const, :ival)&.fetch(:ival, 0) != 0
        end

        # ctes are the query's CTE names. An unqualified name among them may
        # be a CTE, not the table, so it has no keys.
        def deterministic?(transaction, select, ctes)
          table = sole_table(select)
          return false unless table
          return false if !table[:schemaname] && ctes.include?(table[:relname])

          sorted = sorted_columns(select, table)
          keys(transaction, table).any? { |key| (key - sorted).empty? }
        end

        def sole_table(select)
          from = select[:from_clause]
          return unless from&.size == 1 && from.first[:range_var]
          return if select[:group_clause] || select[:distinct_clause] || select[:larg]

          from.first[:range_var]
        end

        # The column names the ORDER BY sorts by as plain columns of table:
        # unqualified or qualified by its alias or name, and not an output
        # alias for something else.
        def sorted_columns(select, table)
          qualifier = table.dig(:alias, :aliasname) || table[:relname]
          aliases = output_aliases(select)
          Array(select[:sort_clause]).filter_map do |sort|
            fields = column_names(sort[:sort_by][:node]) unless sort[:sort_by][:use_op]
            plain_name(fields, qualifier, aliases)
          end
        end

        def plain_name(fields, qualifier, aliases)
          name = fields&.last
          plain = fields&.size == 1 && aliases.fetch(name, name) == name
          name if plain || fields == [qualifier, name]
        end

        # A node's names when it's a plain column reference, or nil.
        def column_names(node)
          names = node&.dig(:column_ref, :fields)&.map { it.dig(:string, :sval) }
          names unless names.nil? || names.any?(&:nil?)
        end

        # Each output alias, with the column name it stands for, or nil.
        def output_aliases(select)
          Array(select[:target_list]).each_with_object({}) do |target, aliases|
            target = target[:res_target]
            aliases[target[:name]] = column_names(target[:val])&.last if target[:name]
          end
        end

        def keys(transaction, table)
          name = [table[:schemaname], table[:relname]].compact.map { %("#{it.gsub('"', '""')}") }.join(".")
          sql = format(KEYS_SQL, table: name.gsub("'", "''"))
          transaction.query(sql).rows.group_by(&:first).values.map { |rows| rows.map(&:last) }
        end
      end
    end
  end
end
