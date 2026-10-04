# frozen_string_literal: true

require_relative "row_set"

module Quaack
  module Enclave
    module Scenarios
      # A scenario's rows, as one or more fixtures, each its own RowSet. A
      # group goes in the first fixture if it fits (see RowSet#add_any?).
      # One that doesn't goes in the next later fixture it fits, or a new
      # one: a parent with no child, when the filter pins a unique column
      # (email = 'a@b') the hit's row already holds. In a later fixture, a
      # group takes with it the rows it points at, and theirs, from the
      # fixtures that hold them. A group that fits none as it is tries its
      # fallbacks (the group as a near miss) the same way, in later fixtures
      # only, so the first holds only groups as the plan built them. One
      # that fits nowhere is left out.
      class Parts
        # How many groups didn't fit the first fixture.
        attr_reader :dropped

        def initialize(schema, conn)
          @schema = schema
          @conn = conn
          @sets = [RowSet.new(schema, conn)]
          @dropped = 0
        end

        # chains: the group's tries, then its fallbacks' (each tries for
        # RowSet#add_any?).
        def add(chains)
          return if @sets.first.add_any?(chains.first)

          @dropped += 1
          chains.any? { spill?(it) }
        end

        # Each fixture's rows (see RowSet#in_order), the first first.
        def in_order(tables) = @sets.map { it.in_order(tables) }

        private

        def spill?(tries)
          lifted = tries.lazy.map { it&.then { |rows| @sets.flat_map { |set| set.parents_of(rows) }.uniq + rows } }
          return true if @sets.drop(1).any? { it.add_any?(lifted) }

          spare = RowSet.new(@schema, @conn)
          spare.add_any?(lifted) && (@sets << spare)
        end
      end
    end
  end
end
