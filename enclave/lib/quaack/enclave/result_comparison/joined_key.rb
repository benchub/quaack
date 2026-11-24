# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparison
      # TotalOrder's exception for a top level that joins. A join can repeat
      # a row of the keyed table, and those repeats tie on its key. They
      # print the same when every output column comes from that table
      # alone: each column reference in the target list, a subquery's among
      # them, is qualified by its name or alias, or is unqualified and names
      # one of its columns, and there's no bare star. Then any order of the
      # ties gives the same output, and the order is total enough.
      module JoinedKey
        COLUMNS_SQL = <<~SQL
          SELECT pg_catalog.count(*)::int FROM pg_catalog.pg_attribute
          WHERE attrelid OPERATOR(pg_catalog.=) pg_catalog.to_regclass('%<table>s') AND attnum OPERATOR(pg_catalog.>) 0
            AND NOT attisdropped AND attname OPERATOR(pg_catalog.=) ANY ('{%<names>s}'::pg_catalog.name[])
        SQL

        module_function

        # extra narrows InnerCuts' keys, as TotalOrder's deterministic keys.
        def keyed?(transaction, top, ctes, extra)
          return false if top[:group_clause] || top[:distinct_clause] || !top[:from_clause]

          table = output_table(transaction, top)
          return false if table.nil? || cte?(table, ctes)

          sorted = InnerCuts.sorted_columns(top, table)
          InnerCuts.keys(transaction, table, extra).any? { |key| (key - sorted).empty? }
        end

        # An unqualified name may be a CTE, not the table, so it has no keys.
        def cte?(table, ctes) = !table[:schemaname] && ctes.include?(table[:relname])

        # The FROM table every output column comes from, or nil.
        def output_table(transaction, top)
          qualifiers = Array(top[:target_list]).map { target_qualifiers(it[:res_target][:val]) }
          return if qualifiers.any?(nil)

          bare, names = qualifiers.flatten(1).uniq.partition { it.is_a?(Array) }
          table = named_table(top, names)
          table if table && table_columns?(transaction, table, bare.map(&:last))
        end

        # The one FROM table named by names, when there's exactly one name.
        def named_table(top, names)
          return unless names.size == 1

          tables = range_vars(top[:from_clause]).select { (it.dig(:alias, :aliasname) || it[:relname]) == names.first }
          tables.first if tables.size == 1
        end

        # The qualifiers of node's column references, [:bare, name] for an
        # unqualified one, or nil when one is a bare star. A subquery's own
        # columns count too, so one that reads another table refuses.
        def target_qualifiers(node)
          case node
          when Array then node.map { target_qualifiers(it) }.then { it.any?(nil) ? nil : it.flatten(1) }
          when Hash
            if (ref = node[:column_ref])
              names = ref[:fields].map { it.dig(:string, :sval) }
              return names.size == 2 && names.first ? [names.first] : bare_name(names)
            end
            target_qualifiers(node.values)
          else []
          end
        end

        # An unqualified column, as [:bare, name], or nil for a bare star.
        def bare_name(names)
          [[:bare, names.first]] if names.size == 1 && names.first
        end

        # Whether table has every column named. An unqualified name that
        # the table has can only mean its column, or Postgres would call
        # it ambiguous.
        def table_columns?(transaction, table, names)
          return true if names.empty?

          sql = format(COLUMNS_SQL, table: quoted(table), names: TotalOrder.elements(names))
          transaction.query(sql).rows.first.first == names.uniq.size.to_s
        end

        # The table's quoted name, in a string literal.
        def quoted(table)
          [table[:schemaname], table[:relname]].compact.map { %("#{it.gsub('"', '""')}") }.join(".").gsub("'", "''")
        end

        # Every table the FROM reads at its own level, through its joins.
        def range_vars(node)
          case node
          when Array then node.flat_map { range_vars(it) }
          when Hash
            return [node[:range_var]] if node[:range_var]

            join = node[:join_expr]
            join ? range_vars([join[:larg], join[:rarg]]) : []
          else []
          end
        end
      end
    end
  end
end
