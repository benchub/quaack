# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The pooled atoms whose near misses get a sibling (see Plan#siblings):
      # those on one table with a parent, whose column a pooled atom in
      # another scope tests too.
      #
      #   Siblings.new(topology, atoms, pooled).tables  # => { 3 => submissions }
      class Siblings
        def initialize(topology, atoms, pooled)
          @topology = topology
          @atoms = atoms
          @pooled = pooled
          @scopes = Scenarios.scopes(atoms)
        end

        def tables = @pooled.filter_map { |i| table(i)&.then { [i, it] } }.to_h

        private

        def table(index)
          tables = @atoms[index].columns.map(&:table).uniq
          return unless tables.size == 1 && @topology.parents(tables[0]).any?

          tables[0] if @pooled.any? { |j| elsewhere?(index, j) }
        end

        def elsewhere?(one, other) = @scopes[one] != @scopes[other] && slots(one).intersect?(slots(other))

        def slots(index) = @atoms[index].columns.map { |c| @topology.slot(c.table, c.name) }
      end
    end
  end
end
