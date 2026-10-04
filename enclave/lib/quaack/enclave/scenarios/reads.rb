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
      # on its own. A star, or a reference whose last name is no column of
      # a fixture table (a whole row, such as t in SELECT t FROM x t, or an
      # output name), counts as reading every column. A JOIN ... USING
      # reads the columns it names, and a NATURAL join reads every column.
      # parse may be a list of parses, read by any of them.
      class Reads
        def initialize(parse, column_names)
          @names = []
          @qualified = []
          @all = false
          known = column_names.values.flatten
          (parse.is_a?(Array) ? parse : [parse]).each do |p|
            tables = Tables.new(p.tree)
            walk(p.tree) { |fields| note(fields, known, tables) }
          end
        end

        def read?(table, name) = @all || @names.include?(name) || @qualified.include?([table, name])

        private

        def walk(node, &)
          yield node.fields.to_a if node.is_a?(PgQuery::ColumnRef)
          join(node) if node.is_a?(PgQuery::JoinExpr)
          ValuePools::Sides.children(node).each { walk(it, &) }
        end

        def join(node)
          @all = true if node.is_natural
          @names.concat(node.using_clause.map { it.string.sval })
        end

        def note(fields, known, tables)
          name = fields.last&.string&.sval
          @all = true unless name && known.include?(name)
          return unless name

          table = qualifier(fields, tables)
          table ? @qualified << [table, name] : @names << name
        end

        def qualifier(fields, tables)
          tables.only(fields[-2].string&.sval) if fields.size > 1
        end

        # The names a query's references can be qualified by, each with
        # what it may name: a TableName, or nil for anything else.
        class Tables
          def initialize(tree)
            @named = Hash.new { |h, k| h[k] = [] }
            collect(tree)
          end

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
              @named[node.alias&.aliasname || node.relname] << table(node)
            elsif node.is_a?(PgQuery::JoinExpr) && node.alias
              @named[node.alias.aliasname] << nil
            end
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
