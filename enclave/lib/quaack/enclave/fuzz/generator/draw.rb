# frozen_string_literal: true

require_relative "uniques"

module Quaack
  module Enclave
    module Fuzz
      class Generator
        # One world: rows table by table in the plan's order, drawn under
        # one swarm Config. A table that gets Copies holds that many rows,
        # and each table its foreign keys point to at least one.
        class Draw # rubocop:disable Metrics/ClassLength -- one world's draw, copies included
          def initialize(generator, rng)
            @generator = generator
            @rng = rng
            @config = Generator.config(rng, generator.order, generator.domains.copies)
            @by_table = Hash.new { |h, k| h[k] = [] }
            @taken = Hash.new { |h, k| h[k] = Set.new }
            @fresh = 0
            @varied = varied
          end

          def rows
            uniques = Uniques.new(catalog, plan, method(:fresh))
            plan.order.flat_map do |table|
              count(table).times do
                row = row(table)
                @by_table[table] << row if row && uniques.admit?(row)
              end
              @by_table[table]
            end
          end

          private

          def domains = @generator.domains

          def plan = @generator.plan

          def catalog = @generator.catalog

          def chance?(rate) = rate.positive? && @rng.rand < rate

          def pick(values) = values.sample(random: @rng)

          def fresh(table, column) = domains.unique(table, column, @fresh += 1)

          def count(table)
            copies = @config.copies
            return copies.count if copies&.table == table

            rows = @config.rows.fetch(table)
            copies && parent?(table, copies.table) ? [rows, 1].max : rows
          end

          # The one column copies may vary in, or nil.
          def varied
            copies = @config.copies or return
            columns = plan.entries_for(copies.table).select { it.kind == :read }.map(&:column)
            pick(columns.reject { domains.grouped?(copies.table, it) })
          end

          def parent?(table, child) = plan.entries_for(child).any? { it.kind == :fk && it.fk.parent == table }

          def row(table)
            cells = {}
            copy = @by_table[table].first if @config.copies&.table == table
            template = pick(@by_table[table]) if !copy && chance?(@config.dup_rate)
            Row.new(table, cells) if plan.entries_for(table).all? { fill(cells, table, it, template, copy) }
          end

          # Gives the entry's column its value, unless an earlier foreign
          # key gave it one; false when it can't. A copy takes the first
          # row's where it keeps it.
          def fill(cells, table, entry, template, copy)
            return true if cells.key?(entry.column)
            return copied(cells, entry, copy) if copy && keep?(table, entry)
            return parent(cells, entry.fk) if entry.kind == :fk

            cells[entry.column] = value(table, entry, template)
            true
          end

          # Whether a copy keeps the first row's value in the entry's
          # column: never in a unique one the plan fills fresh, and in the
          # varied column but at the vary rate.
          def keep?(_table, entry)
            return false if %i[pk unique].include?(entry.kind)

            entry.column != @varied || !chance?(@config.copies.vary)
          end

          def copied(cells, entry, copy) # rubocop:disable Naming/PredicateMethod -- fill's contract: true when filled
            columns = entry.kind == :fk ? entry.fk.columns : [entry.column]
            columns.each { cells[it] = copy.cells[it] }
            true
          end

          def value(table, entry, template)
            column = entry.column
            case entry.kind
            when :pk then pk(table, column)
            when :key then key(table, column)
            when :read then template ? template.cells[column] : read(table, column)
            when :unique then fresh(table, column)
            when :required then domains.typical(table, column).first
            end
          end

          # A kept foreign key's columns, from a parent row in the world, or
          # NULL; false when the key can be neither.
          def parent(cells, key)
            nullable = plan.fk_nullable?(key)
            chosen = pick(@by_table[key.parent]) unless nullable && chance?(@config.null_rate)
            copy(cells, key, chosen ? chosen.cells : {})
            nullable || !chosen.nil?
          end

          def copy(cells, key, source) = key.columns.zip(key.parent_columns).each { |c, p| cells[c] = source[p] }

          def pk(table, column)
            taken = @taken[[table, column]]
            value = pick_untaken(table, column, taken) || fresh(table, column)
            taken << value
            value
          end

          def pick_untaken(table, column, taken)
            pool = domains.class_values(table, column) + domains.base_keys(table, column).first(@config.key_pool + 1)
            pool.uniq.shuffle(random: @rng).find { !taken.include?(it) }
          end

          def key(table, column)
            return nil if null?(table, column)

            values = domains.class_values(table, column)
            return pick(values) if values.any? && @rng.rand < @config.literal_bias

            pick(domains.base_keys(table, column).first(@config.key_pool))
          end

          def read(table, column)
            return nil if null?(table, column)

            boundary(table, column) || world(table, column) || own(table, column) || ordinary(table, column)
          end

          def boundary(table, column) = chance?(@config.boundary_rate) ? pick(domains.boundaries(table, column)) : nil

          def world(table, column) = chance?(@config.world_rate) ? pick(domains.world(table, column)) : nil

          # One of the queries' own values for the column, at the world's
          # literal bias.
          def own(table, column)
            values = domains.values(table, column).compact
            pick(values) if values.any? && @rng.rand < @config.literal_bias
          end

          def ordinary(table, column)
            typical = domains.typical(table, column)
            pick(typical.empty? ? domains.values(table, column).compact : typical)
          end

          def null?(table, column)
            catalog.column(table, column).nullable && chance?(@config.null_rate)
          end
        end
      end
    end
  end
end
