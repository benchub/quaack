# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Which groups make up each scenario (see Scenarios).
      class Plan
        # masked maps an atom to its masking near miss's also atoms.
        def initialize(topology, atoms, pooled, masked = {})
          @topology = topology
          @atoms = atoms
          @pooled = pooled
          @masked = masked
          @next_key = 0
        end

        def scenarios
          hit = group(fresh_key)
          near = pooled_near_misses
          base = [hit, *near, *join_near_misses]
          extras = { s1: [], s2: [nulls], s3: fan_outs(hit, near), s4: orphans, s5: boundaries }
          masking = masking_near_misses
          { s0: [], **extras.transform_values { base + it + masking }, s6: [hit] + many + [empty] }
        end

        private

        def pooled_near_misses = @pooled.map { |i| group(fresh_key, near: i) }

        # Last in each scenario that holds them, so a unique-key collision
        # leaves them out before any other group.
        def masking_near_misses = @masked.map { |i, also| group(fresh_key, near: i, also:) }

        def nulls = group(fresh_key, mode: :nulls)

        def empty = group(fresh_key, @topology.roots)

        # Crosses come first, so that when a unique column's filter leaves
        # one value after the hit's, a cross takes it.
        def fan_outs(hit, near) = crosses(hit, near) + copies(hit)

        def copies(hit) = order.map { |t| group(hit.key, [t], copy: 1) }

        # For each foreign key a row can point across groups (see
        # Topology#crossings), a group whose row points it at the hit's
        # parent, not its own, with no parent of its own that nothing else
        # needs, and all its children for a cut key (see Topology#cross_tables). A key the table holds unique
        # can't point at the hit's parent, which has its child, so it
        # points at a parent of its own group's, with no child (a has_one).
        # A self-reference points at a row of its own table, and is crossed
        # with each near miss too: a row that fails the atom, pointing at the
        # hit's, so a filter on the child and one on its parent differ.
        def crosses(hit, near)
          @topology.crossings.flat_map do |table, foreign|
            parent = childless_parent(table, foreign)
            plain = cross(table, foreign, parent&.key || hit.key)
            self_references?(table, foreign) ? [plain] + near_crosses(table, foreign, hit, near) : [*parent, plain]
          end
        end

        def childless_parent(table, foreign)
          return unless @topology.unique_key?(table, foreign) && !self_references?(table, foreign)

          group(fresh_key, @topology.ancestors(foreign.parent))
        end

        def near_crosses(table, foreign, hit, near)
          near.map { |miss| cross(table, foreign, hit.key, near: miss.near) }
        end

        def cross(table, foreign, target, **)
          across = Cross.new(table:, columns: foreign.columns, key: target)
          group(fresh_key, @topology.cross_tables(table, foreign), cross: across, **)
        end

        def self_references?(table, foreign) = foreign.parent == table

        # The reversed group comes first, so its larger values go with the
        # smaller keys, and an ORDER BY on a boundary value can't agree with
        # one on the keys.
        def boundaries = %i[boundary_reversed boundary].map { |mode| group(fresh_key, mode:) }

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
