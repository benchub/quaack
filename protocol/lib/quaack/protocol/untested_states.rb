# frozen_string_literal: true

module Quaack
  module Protocol
    # How each untested atom of a report rewrite stayed unproven
    # (DESIGN.md, "vacuity-guard"): untested_states is an Array with one
    # word from WORDS per entry of the same entry's untested_atoms, in its
    # order. searched: vacuity-guard's search spent its whole trial budget
    # on the atom and found no difference. not_searched: the search's
    # clock or fixture cap stopped it first, or it didn't run. A message
    # from before 20261010-43 has no untested_states, and is still valid.
    #
    #   UntestedStates.valid?([{ "untested_atoms" => ["a < $1"], "untested_states" => ["searched"] }])  # => true
    module UntestedStates
      WORDS = %w[searched not_searched].freeze

      module_function

      def valid?(rewrites) = rewrites.is_a?(Array) && rewrites.all? { entry?(it) }

      def entry?(entry)
        return false unless entry.is_a?(Hash)

        states = field(entry, "untested_states")
        return true if states.nil?

        atoms = field(entry, "untested_atoms")
        states.is_a?(Array) && atoms.is_a?(Array) && states.size == atoms.size &&
          states.all? { WORDS.include?(it) }
      end

      def field(entry, name) = entry.fetch(name) { entry[name.to_sym] }

      private_class_method :entry?, :field
    end
  end
end
