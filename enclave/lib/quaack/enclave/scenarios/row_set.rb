# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # A scenario's rows, gathered a group at a time. A row already there
      # is kept once. A group with a row that would collide with an earlier
      # one on a primary key or unique constraint is left out whole.
      class RowSet
        def initialize(schema)
          @schema = schema
          @rows = Hash.new { |h, k| h[k] = [] }
        end

        # False when the group collides and is left out.
        def add(group_rows)
          fresh = group_rows.reject { |r| @rows[r.table].include?(r) }
          return false if fresh.any? { |r| collides?(r) }

          fresh.each { |r| @rows[r.table] << r }
          true
        end

        def in_order(tables) = tables.flat_map { |t| @rows[t] }

        private

        def collides?(row)
          @schema.constraints(row.table).uniques.any? do |columns|
            key = values(row, columns)
            key.none?(&:nil?) && @rows[row.table].any? { |other| values(other, columns) == key }
          end
        end

        def values(row, columns) = columns.map { |c| row.columns.index(c)&.then { |i| row.values[i] } }
      end
    end
  end
end
