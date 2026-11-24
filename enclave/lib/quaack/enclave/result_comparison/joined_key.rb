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

        # pg_query's frame_options for a window with no frame clause.
        DEFAULT_FRAME = 1058

        module_function

        # extra narrows InnerCuts' keys, as TotalOrder's deterministic keys.
        def keyed?(transaction, top, ctes, extra)
          return false if top[:group_clause] || top[:distinct_clause] || !top[:from_clause]

          table = output_table(transaction, top)
          return false if table.nil? || cte?(table, ctes)

          covers = [InnerCuts.sorted_columns(top, table), *window_partitions(top, table)]
          InnerCuts.keys(transaction, table, extra).any? { |key| covers.all? { (key - it).empty? } }
        end

        # The table's columns each target-list window partitions by. Rows
        # that tie on the key are one row repeated; a window partitioned by
        # the key gives them the same value, and any other can tell them
        # apart. One with an ORDER BY or a frame can still tell them apart
        # inside the partition, so it refuses too. A window in a subquery
        # refuses as well: the outer key is one value there, not a partition
        # of the outer rows.
        def window_partitions(top, table)
          windows(top[:target_list]).map do |over, nested|
            ordered?(over) || nested ? [] : partition_columns(over[:partition_clause], table)
          end
        end

        # Whether a window can tell a partition's rows apart, by its ORDER
        # BY or an explicit frame, or names a window whose partition we
        # don't read.
        def ordered?(over)
          over[:name] || over[:refname] || over[:order_clause] || over[:frame_options] != DEFAULT_FRAME
        end

        # Each window under node, with whether it sits in a subquery.
        def windows(node, nested: false)
          case node
          when Array then node.flat_map { windows(it, nested:) }
          when Hash
            over = node.dig(:func_call, :over)
            (over ? [[over, nested]] : []) + windows(node.values, nested: nested || node.key?(:sub_link))
          else []
          end
        end

        # Plain columns of table in a PARTITION BY, by name.
        def partition_columns(clause, table)
          own = table.dig(:alias, :aliasname) || table[:relname]
          Array(clause).filter_map { own_column(it, own) }
        end

        # A column reference's name when it's own's column, plain or
        # qualified by own.
        def own_column(item, own)
          names = Array(item.dig(:column_ref, :fields)).map { it.dig(:string, :sval) }
          return unless names.all? && [1, 2].include?(names.size)

          names.last if names.size == 1 || names.first == own
        end

        # An unqualified name may be a CTE, not the table, so it has no keys.
        def cte?(table, ctes) = !table[:schemaname] && ctes.include?(table[:relname])

        # The FROM table every output column comes from, or nil.
        def output_table(transaction, top)
          qualifiers = Array(top[:target_list]).map { target_qualifiers(it[:res_target][:val]) }
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
