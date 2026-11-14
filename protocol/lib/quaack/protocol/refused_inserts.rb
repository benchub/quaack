# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of a counterexample_round's refused (DESIGN.md's
    # llm-counterexamples): each refused insert's 0-based index, its rule, a
    # lowercase word, and, for a not_immutable refusal only, function, the
    # schema-qualified name of the catalog function that got it refused, such
    # as pg_catalog.timezone (task 20261012-12). The name comes from
    # pg_proc, for a call the insert's own text makes, never from a value. It
    # must be two plain lowercase identifiers, so a quoted name, which could
    # hold anything, never goes out: the enclave leaves function off then.
    module RefusedInserts
      KEYS = %w[index rule function].freeze
      RULE = /\A[a-z][a-z0-9_]*\z/
      FUNCTION = /\A[a-z_][a-z0-9_$]*\.[a-z_][a-z0-9_$]*\z/

      module_function

      # Whether refused, as the enclave sends it (Symbol or String keys) or
      # JSON reads it back, is an Array of exactly such entries.
      def valid?(refused) = refused.is_a?(Array) && refused.all? { entry?(it) }

      def entry?(entry)
        fields = fields(entry)
        return false unless fields

        index, rule = fields.values_at("index", "rule")
        index.is_a?(Integer) && index >= 0 && rule?(rule) &&
          (!fields.key?("function") || function?(rule, fields["function"]))
      end

      # entry with String keys, or nil if it isn't a Hash, names a key twice,
      # or has a key not in KEYS.
      def fields(entry)
        return unless entry.is_a?(Hash)

        fields = entry.to_h { |key, value| [key.to_s, value] }
        fields if fields.size == entry.size && (fields.keys - KEYS).empty?
      end

      def rule?(rule) = rule.is_a?(String) && RULE.match?(rule)

      def function?(rule, function) = rule == "not_immutable" && function.is_a?(String) && FUNCTION.match?(function)
    end
  end
end
