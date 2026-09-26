# frozen_string_literal: true

require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # Picks the value for a slot that pooled atoms constrain: the first
      # pool value that satisfies each atom (or fails the near-miss one) and
      # every CHECK on the slot's columns. variants rotates an atom's pool
      # lists, by atom index.
      class Picker
        def initialize(pools, probes, checks, variants)
          @pools = pools
          @probes = probes
          @checks = checks
          @variants = variants
          @picks = {}
        end

        # :skip when a near miss has no value.
        def pick(atoms, columns, near, mode)
          @picks[[atoms, columns, near, mode]] ||= begin
            candidates = prefer_boundaries(candidates(atoms, near), atoms, mode)
            index = candidates.index { |v| fits?(atoms, columns, near, v) }
            if index then candidates[index]
            else
              near ? :skip : candidates.fetch(0, :skip)
            end
          end
        end

        private

        def candidates(atoms, near)
          return rotated(@pools[near].failing, near) if near

          atoms.flat_map { |i| rotated(@pools[i].satisfying, i) }
        end

        def rotated(list, atom) = list.rotate(@variants.fetch(atom, 0) % [list.size, 1].max)

        def prefer_boundaries(candidates, atoms, mode)
          return candidates unless mode.to_s.start_with?("boundary")

          bounds = atoms.flat_map { |i| @pools[i].boundaries }
          bounds = bounds.reverse if mode == :boundary_reversed
          (bounds & candidates) + candidates
        end

        def fits?(atoms, columns, near, value)
          atoms.all? { |i| @probes[i].call(value) == (i == near ? "f" : "t") } &&
            columns.all? { |t, col| @checks.allows?(t, col, value) }
        end
      end
    end
  end
end
