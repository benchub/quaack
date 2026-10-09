# frozen_string_literal: true

module Quaack
  module Protocol
    # The kinds of change selection ranks apart (DESIGN.md's selection), from
    # a fixed list. A ranked label in the report's top carries its kind.
    module CandidateKinds
      # In the order the report lists them.
      KINDS = %w[rewrite_new_indexes rewrite_same_indexes original_new_indexes].map(&:freeze).freeze

      module_function

      # The kind of a measured label such as "original:top:1" or
      # "rewrite_2:none", or nil for one that is no candidate ("original:none"
      # is the baseline itself).
      def of(label)
        search, key = label.to_s.split(":", 2)
        return key == "none" ? nil : "original_new_indexes" if search == "original"

        key == "none" ? "rewrite_same_indexes" : "rewrite_new_indexes"
      end

      # Whether top, as JSON reads it back, is an Array of Hashes that each
      # carry a kind from KINDS (a String key "kind").
      def valid?(top)
        top.is_a?(Array) && top.all? { it.is_a?(Hash) && KINDS.include?(it["kind"] || it[:kind]) }
      end
    end
  end
end
