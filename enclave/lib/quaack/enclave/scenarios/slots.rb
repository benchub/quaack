# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Each slot's pooled atoms and its columns, for the Builder. The pools
      # and the topology never change, so each slot's are found once:
      # finding a slot's members walks every column of every foreign key.
      class Slots
        def initialize(topology, pools, schema)
          @topology = topology
          @pools = pools
          @schema = schema
          @atoms = {}
          @columns = {}
        end

        # The indexes of the pools whose column is one of the slot's.
        def atoms(slot)
          @atoms[slot] ||= begin
            members = @topology.members(slot)
            @pools.keys.select { |i| members.include?([@pools[i].column.table, @pools[i].column.name]) }.freeze
          end
        end

        # Each of the slot's columns, as [table, column].
        def columns(slot) = @columns[slot] ||= @topology.members(slot).map { |t, n| [t, @schema.column(t, n)] }.freeze
      end
    end
  end
end
