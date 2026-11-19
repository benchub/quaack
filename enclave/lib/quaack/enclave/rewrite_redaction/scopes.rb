# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module RewriteRedaction
      # The names a SELECT's FROM binds, for Comparison's column resolution.
      # A name bound to a CTE (20261020-2) resolves to the CTE's one table
      # when its body is one plain SELECT from one table, selecting * or
      # plain columns of it. Any other CTE gives a Cte with no table and no
      # columns, so its columns keep the CTE's name and match no original
      # comparison. A nearer WITH shadows an outer one of the same name.
      module Scopes
        # name: the CTE's name. table: the table it reads, or nil.
        # columns: { output column => that table's column }, or nil for *.
        Cte = Data.define(:name, :table, :columns)

        module_function

        # Each SELECT above, outermost first, as { name in FROM => table name, Cte, or nil }.
        def of(above)
          ctes = {}
          above.filter_map do |message, _, _|
            next unless message.is_a?(PgQuery::SelectStmt)

            ctes = visible(message, ctes)
            message.from_clause.each_with_object({}) { |node, names| add_from(node, names, ctes) }
          end
        end

        # [table or nil, column] for a column of entry, a table name or a Cte.
        def through(entry, column)
          return [entry, column] unless entry.is_a?(Cte)

          source = entry.columns ? entry.columns[column] : column
          source ? [entry.table, source] : [entry.name, column]
        end

        def range_name(range) = range.alias&.aliasname || range.relname

        def add_from(node, names, ctes)
          if (range = node.range_var)
            names[range_name(range)] = target(range, ctes)
          elsif (join = node.join_expr)
            [join.larg, join.rarg].each { add_from(it, names, ctes) }
          elsif (sub = node.range_subselect)&.alias
            names[sub.alias.aliasname] = nil
          end
        end

        # The CTEs visible inside select, its own WITH's over the enclosing
        # ones, each name => [CTE, the CTEs its body sees]. A non-recursive
        # body sees only the siblings before it; a RECURSIVE one sees all.
        def visible(select, ctes)
          list = select.with_clause&.ctes.to_a.filter_map(&:common_table_expr)
          return ctes if list.empty?

          everything = {}
          found = list.each_with_object(ctes.dup) do |cte, before|
            before[cte.ctename] = [cte, select.with_clause.recursive ? everything : before.dup]
          end
          everything.merge!(found)
        end

        # A table name for an ordinary range, or a Cte for one naming a visible CTE.
        def target(range, ctes, seen = [])
          cte, env = ctes[range.relname] if range.schemaname.empty?
          return range.relname unless cte

          resolved(cte, env, seen) || Cte.new(name: range.relname, table: nil, columns: {})
        end

        def resolved(cte, ctes, seen)
          body = cte.ctequery&.select_stmt
          range = single_range(body) unless seen.include?(cte.ctename)
          return unless range

          columns = columns(body.target_list.map(&:res_target), range_name(range))
          compose(cte.ctename, target(range, visible(body, ctes), seen + [cte.ctename]), columns) if columns
        end

        def single_range(body)
          return unless body && body.op == :SETOP_NONE && body.from_clause.size == 1

          body.from_clause.first.range_var
        end

        # A Cte for name over inner, the table or Cte its body reads.
        def compose(name, inner, columns)
          columns = nil if columns == :star
          return Cte.new(name:, table: inner, columns:) unless inner.is_a?(Cte)
          return Cte.new(name:, table: inner.table, columns: inner.columns) unless columns

          mapped = columns.transform_values { inner.columns ? inner.columns[it] : it }.compact
          Cte.new(name:, table: inner.table, columns: mapped)
        end

        # { output => column } for a target list of plain columns of the one
        # table, :star for a lone unnamed *, nil for anything else.
        def columns(list, from_name)
          return :star if star?(list, from_name)

          list.each_with_object({}) do |target, map|
            column = field(target.val, from_name)
            return nil unless column.is_a?(String)

            map[target.name.empty? ? column : target.name] = column
          end
        end

        def star?(list, from_name)
          list.size == 1 && list.first.name.empty? && field(list.first.val, from_name) == :star
        end

        def name(field) = field.a_star ? :star : field.string&.sval

        # A plain column ref's column name, or :star for *, or nil.
        def field(val, from_name)
          ref = val&.column_ref
          return unless ref

          names = ref.fields.map { name(it) }
          names = names.drop(1) if names.first == from_name && names.size == 2
          names.first if names.size == 1
        end
      end
    end
  end
end
