# frozen_string_literal: true

require "pg_query"
require_relative "../table_name"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # Whether a query may read a column of a table, erring toward yes.
      # A reference qualified by a name that, across the whole query, names
      # just one schema-qualified table (its alias, or its name when it has
      # none) reads that table's column. Any other reference reads the
      # column of that name in every table. A join's alias names no table,
      # since its columns need no reference inside it. A subquery's or
      # CTE's column comes from a reference or star inside it, which counts
      # on its own. A table aliased with a column list (c(a, b)) renames its
      # columns, so any reference to it counts as reading every column of
      # it. A star, or a reference whose last name is no column of
      # a fixture table (a whole row, such as t in SELECT t FROM x t, or an
      # output name), counts as reading every column. A JOIN ... USING
      # reads the columns it names, and a NATURAL join reads every column.
      # parse may be a list of parses, read by any of them.
      #
      # aggregate gives how the query aggregates a column (20261010-36):
      # :min when only min() reads it, :other when max(), sum(), or avg()
      # does, and nil when none of them does. A reference counts as it does
      # for read?, so an unqualified one counts for every table.
      class Reads
        AGGREGATES = %w[min max sum avg].freeze

        def initialize(parse, column_names)
          @names = []
          @qualified = []
          @aggregated = Hash.new { |h, k| h[k] = [] }
          @all = false
          @whole = []
          known = column_names.values.flatten
          (parse.is_a?(Array) ? parse : [parse]).each do |p|
            tables = Tables.new(p.tree)
            @whole.concat(tables.renamed)
            walk(p.tree, nil) { |fields, agg| note(fields, known, tables, agg) }
          end
        end

        def read?(table, name)
          @all || @whole.include?(table) || @names.include?(name) || @qualified.include?([table, name])
        end

        def aggregate(table, name)
          found = @aggregated[[table, name]] + @aggregated[[nil, name]]
          return if found.empty?

          found.uniq == ["min"] ? :min : :other
        end

        private

        # agg is the name of the aggregate the node is an argument of. An
        # aggregate's FILTER isn't its argument.
        def walk(node, agg, &)
          yield node.fields.to_a, agg if node.is_a?(PgQuery::ColumnRef)
          join(node) if node.is_a?(PgQuery::JoinExpr)
          inner = aggregate_name(node)
          return ValuePools::Sides.children(node).each { walk(it, agg, &) } unless inner

          node.class.descriptor.each { |field| walk(field.get(node), field.name == "args" ? inner : agg, &) }
        end

        def aggregate_name(node)
          return unless node.is_a?(PgQuery::FuncCall)

          name = node.funcname.last&.string&.sval
          name if AGGREGATES.include?(name)
        end

        def join(node)
          @all = true if node.is_natural
          @names.concat(node.using_clause.map { it.string.sval })
        end

        def note(fields, known, tables, agg)
          name = fields.last&.string&.sval
          @all = true unless name && known.include?(name)
          return unless name

          table = qualifier(fields, tables)
          table ? @qualified << [table, name] : @names << name
          @aggregated[[table, name]] << agg if agg
        end

        def qualifier(fields, tables)
          tables.only(fields[-2].string&.sval) if fields.size > 1
        end

        # The names a query's references can be qualified by, each with
        # what it may name: a TableName, or nil for anything else.
        class Tables
          def initialize(tree)
            @named = Hash.new { |h, k| h[k] = [] }
            @renamed = []
            collect(tree)
          end

          # The tables aliased with a column list.
          attr_reader :renamed

          # The one table name names, or nil.
          def only(name)
            found = @named.fetch(name, []).uniq
            found.first if found.size == 1
          end

          private

          def collect(node)
            add(node)
            ValuePools::Sides.children(node).each { collect(it) }
          end

          def add(node)
            if node.is_a?(PgQuery::RangeVar)
              range(node)
            elsif node.is_a?(PgQuery::JoinExpr) && node.alias
              @named[node.alias.aliasname] << nil
            end
          end

          def range(node)
            @named[node.alias&.aliasname || node.relname] << table(node)
            @renamed << table(node) if node.alias && !node.alias.colnames.empty?
          end

          # nil for a name with no schema, such as a CTE's.
          def table(range)
            TableName.new(schema: range.schemaname, name: range.relname) unless range.schemaname.empty?
          end
        end
      end
    end
  end
end
