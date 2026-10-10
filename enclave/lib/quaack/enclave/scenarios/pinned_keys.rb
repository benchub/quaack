# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The value of a column pooled atoms constrain, for one build. A join
      # key the atoms pin (a.id IN (1, 2, 3)) takes its group's own key
      # value (key gives it) when that fits the group's pick (see
      # Picker#fits_for?): a near miss of the list, say, gets a key of its
      # own outside it. Else the key takes a pool value, each key (see
      # Group#key_for) its own in the order the build first asks, so groups
      # don't all take the first and collide: the pick shifts by the key's
      # rank. Columns that share a key share its rank, so a child still
      # joins its own group's parent. Any other column takes the plain pick.
      class PinnedKeys
        def initialize(topology, slots, picker, &key)
          @topology = topology
          @slots = slots
          @picker = picker
          @key = key
          @ranks = {}
        end

        def value(slot, atoms, group, table, name)
          columns = @slots.columns(slot)
          return @picker.pick_for(atoms, columns, group) unless @topology.keyed?(table, name)

          own = @key.call(slot, group, table, name)
          return own if @picker.fits_for?(atoms, columns, group, own)

          @picker.pick_for(atoms, columns, group, rank(slot, group, table, name))
        end

        private

        def rank(slot, group, table, name)
          ranks = @ranks[slot] ||= {}
          ranks[group.key_for(table, name, own: @topology.own_key?(table, name))] ||= ranks.size
        end
      end
    end
  end
end
