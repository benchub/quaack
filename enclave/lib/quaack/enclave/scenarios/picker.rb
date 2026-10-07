# frozen_string_literal: true

require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # Picks the value for a slot that pooled atoms constrain: the first
      # pool value, or else CHECK value, that satisfies each atom (or fails
      # the near-miss one) and every CHECK on the slot's columns. variants
      # rotates an atom's pool lists, by atom index.
      class Picker
        def initialize(pools, probes, checks, variants)
          @pools = pools
          @probes = probes
          @checks = checks
          @variants = variants
          @picks = {}
        end

        # The atoms some stored value satisfies. One no stored value can,
        # such as r.id IS NULL on a NOT NULL key that an outer join reads,
        # doesn't constrain the slot: every value already fails it, so its
        # near miss needs none.
        def satisfiable(atoms) = atoms.reject { |i| @pools[i].satisfying.empty? }

        # :skip when a near miss has no value. With no value that fits every
        # atom, it takes the first that passes the CHECKs, or :skip when none
        # does, rather than load a row that breaks a CHECK. shift takes the
        # value after that many others that fit, or the first when there are
        # no more.
        def pick(atoms, columns, near, mode, shift = 0)
          @picks[[atoms, columns, near, mode, shift]] ||= begin
            candidates = prefer_boundaries(candidates(atoms, near), atoms, mode) | checked(columns)
            fitting = candidates.lazy.select { |v| fits?(atoms, columns, near, v) }.first(shift + 1)
            if fitting.size > shift then fitting[shift]
            elsif shift.positive? then pick(atoms, columns, near, mode)
            else fallback(candidates, columns, near)
            end
          end
        end

        private

        def fallback(candidates, columns, near)
          return :skip if near

          candidates.find { |v| allowed?(columns, v) } || :skip
        end

        def candidates(atoms, near)
          return rotated(@pools[near].failing, near) if near

          atoms.flat_map { |i| rotated(@pools[i].satisfying, i) }
        end

        # The CHECKs' own values, for when no pool value passes them.
        def checked(columns) = columns.flat_map { |t, col| @checks.values(t, col) }

        def rotated(list, atom) = list.rotate(@variants.fetch(atom, 0) % [list.size, 1].max)

        def prefer_boundaries(candidates, atoms, mode)
          return candidates unless mode.to_s.start_with?("boundary")

          bounds = atoms.flat_map { |i| @pools[i].boundaries }
          bounds = bounds.reverse if mode == :boundary_reversed
          (bounds & candidates) + candidates
        end

        def fits?(atoms, columns, near, value)
          atoms.all? { |i| @probes[i].call(value) == (i == near ? "f" : "t") } && allowed?(columns, value)
        end

        def allowed?(columns, value) = columns.all? { |t, col| @checks.allows?(t, col, value) }
      end
    end
  end
end
