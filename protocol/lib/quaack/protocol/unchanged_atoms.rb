# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of what a report rewrite says about the untested atoms the
    # rewrite left unchanged (DESIGN.md, "unchanged-atoms"): untested_unchanged
    # is an Array of redacted shapes, each one of the same entry's
    # untested_atoms, so it never carries a new string.
    #
    #   UnchangedAtoms.valid?([{ "untested_atoms" => ["a < $1"], "untested_unchanged" => ["a < $1"] }])  # => true
    module UnchangedAtoms
      module_function

      # Whether rewrites, the report's rewrite entries, is an Array of Hashes
      # (String or Symbol keys) each with no untested_unchanged, or with one
      # that's an Array of Strings found in its untested_atoms.
      def valid?(rewrites)
        rewrites.is_a?(Array) && rewrites.all? { entry?(it) }
      end

      def entry?(entry)
        return false unless entry.is_a?(Hash)

        unchanged = field(entry, "untested_unchanged")
        return true if unchanged.nil?

        atoms = field(entry, "untested_atoms")
        strings?(unchanged) && strings?(atoms) && unchanged.all? { atoms.include?(it) }
      end

      def field(entry, name) = entry.fetch(name) { entry[name.to_sym] }

      def strings?(list) = list.is_a?(Array) && list.all?(String)

      private_class_method :entry?, :field, :strings?
    end
  end
end
