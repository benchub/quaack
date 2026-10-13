# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      class Generator
        # Keeps a world's rows unique on their tables' unique keys. A row
        # that would collide gets a fresh value in one of the key's columns
        # the plan fills (FIXABLE), or is left out.
        class Uniques
          FIXABLE = %i[read key required unique pk].freeze

          def initialize(catalog, plan, fresh)
            @catalog = catalog
            @plan = plan
            @fresh = fresh
            @used = Hash.new { |h, k| h[k] = Set.new }
          end

          def admit?(row)
            keys = @catalog.unique_keys(row.table)
            return false unless keys.all? { fixed?(row, it) }

            keys.each do |columns|
              tuple = tuple(row, columns)
              @used[[row.table, columns]] << tuple unless tuple.any?(&:nil?)
            end
            true
          end

          private

          def fixed?(row, columns)
            used = @used[[row.table, columns]]
            return true unless used.include?(tuple(row, columns))

            fixable = columns.find { FIXABLE.include?(@plan.kind(row.table, it)) }
            return false unless fixable

            row.cells[fixable] = @fresh.call(row.table, fixable)
            !used.include?(tuple(row, columns))
          end

          def tuple(row, columns) = columns.map { row.cells[it] }
        end
      end
    end
  end
end
