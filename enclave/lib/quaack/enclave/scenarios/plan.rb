# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Which groups make up each scenario (see Scenarios).
      class Plan
        def initialize(topology, atoms, pooled)
          @topology = topology
          @atoms = atoms
          @pooled = pooled
          @next_key = 0
        end

        def scenarios
          hit = group(fresh_key)
          s1 = [hit] + near_misses
          { s0: [], s1:, s2: s1 + [nulls], s3: s1 + fan_outs(hit),
            s4: s1 + orphans, s5: s1 + boundaries, s6: [hit] + many + [empty] }
        end

        private

        def near_misses = @pooled.map { |i| group(fresh_key, near: i) } + join_near_misses

        def nulls = group(fresh_key, mode: :nulls)

        def empty = group(fresh_key, @topology.roots)

        def fan_outs(hit) = copies(hit) + crosses(hit)

        def copies(hit) = order.map { |t| group(hit.key, [t], copy: 1) }

        # For each foreign key a row can point across groups (see
        # Topology#crossings), a group whose row points it at the hit's
        # parent, not its own.
        def crosses(hit)
          @topology.crossings.map do |table, fk|
            group(fresh_key, @topology.ancestors(table), cross: Cross.new(table:, columns: fk.columns, key: hit.key))
          end
        end

        def boundaries = %i[boundary boundary_reversed].map { |mode| group(fresh_key, mode:) }

        def order = @topology.order

        def fresh_key = @next_key += 1

        def group(key, tables = order, **) = Scenarios.group(key, tables, **)

        def many
          key = fresh_key
          [group(key)] + [1, 2].product(order).map { |copy, t| group(key, [t], copy:) }
        end

        def join_near_misses
          @topology.free_joins.map { |i| group(fresh_key, split: @atoms[i].columns[1].table) }
        end

        def orphans
          @topology.free_joins.flat_map do |i|
            @atoms[i].columns.map(&:table).uniq.map { |t| group(fresh_key, @topology.ancestors(t)) }
          end
        end
      end
    end
  end
end
