# frozen_string_literal: true

require_relative "../../arena_runner"
require_relative "../../value_pools"

module Quaack
  module Enclave
    module VacuityGuard
      class Search
        # Makes the search's trial databases (Search).
        #
        #   trials = Trials.new(schema, order, value_rows, pools, Random.new(SEED))
        #   trials.make(2)  # => [FixtureRow, ...], 1 or 2 rows a table, parents first
        #
        # Each trial holds 1 to max rows a table of the tables value_rows
        # load, in order. A column takes a value some row of value_rows
        # holds for it, a value of an atom's pool, a boundary of its type,
        # true or false for a boolean, or NULL when it's nullable. A
        # single-column foreign key picks a parent row the trial holds (or
        # NULL when nullable), and a unique column a value no earlier row of
        # the table took.
        class Trials
          def initialize(schema, order, value_rows, pools, random)
            @schema = schema
            @random = random
            @values = values(value_rows, pools)
            @order = order.select { @values.key?(it) }
          end

          def make(max)
            present = {}
            @order.flat_map do |table|
              used = Hash.new { |h, k| h[k] = [] }
              built = []
              @random.rand(1..max).times { built << row(table, present, built, used) }
              present[table] = built
              built.map { ArenaRunner::FixtureRow.new(table:, columns: it.keys, values: it.values, deferred: []) }
            end
          end

          private

          def row(table, present, built, used)
            constraints = @schema.constraints(table)
            unique = constraints.uniques.flatten
            @values.fetch(table).to_h do |name, options|
              fk = constraints.foreign_keys.find { it.columns == [name] }
              [name, if fk
                       parent(table, name, fk, fk.parent == table ? built : present.fetch(fk.parent, []))
                     else
                       pick(options, unique.include?(name), used[name])
                     end]
            end
          end

          def parent(table, name, foreign, parents)
            options = parents.map { it[foreign.parent_columns.first] }
            options << nil if @schema.column(table, name).nullable || options.empty?
            options.sample(random: @random)
          end

          def pick(options, unique, used)
            return options.sample(random: @random) unless unique

            fresh = options - used
            (fresh.empty? ? options : fresh).sample(random: @random).tap { used << it }
          end

          # Each table's columns and the values a trial picks from.
          def values(value_rows, pools)
            sets = Hash.new { |h, k| h[k] = Hash.new { |c, n| c[n] = [] } }
            value_rows.each { add_row(sets, it) }
            pools.each_value { add_pool(sets, it) }
            sets.to_h { |table, columns| [table, settle(table, columns)] }
          end

          def add_row(sets, row) = row.columns.zip(row.values).each { |c, v| sets[row.table][c] << v }

          def add_pool(sets, pool)
            return unless pool.respond_to?(:column) && sets.key?(pool.column.table)

            sets[pool.column.table][pool.column.name].push(*pool.satisfying, *pool.failing, *pool.boundaries)
          end

          # The table's columns' values, with every column a trial may set.
          def settle(table, columns)
            @schema.columns(table).each { widen(columns, it) }
            columns.to_h { |name, v| [name, v.compact.uniq + nulls(table, name)] }
          end

          def widen(columns, col)
            extra = extra(col)
            columns[col.name].concat(extra) if columns.key?(col.name) || (!extra.empty? && !generated?(col))
          end

          def nulls(table, name) = @schema.column(table, name).nullable ? [nil] : []

          def extra(col) = col.type == "boolean" ? %w[true false] : ValuePools.boundaries(col.type)

          def generated?(col) = %w[generated identity].include?(col.default)
        end
      end
    end
  end
end
