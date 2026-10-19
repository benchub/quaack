# frozen_string_literal: true

module Quaack
  module Protocol
    # The kinds of change selection ranks apart (DESIGN.md's selection), from
    # a fixed list. A ranked label in the report's top carries its kind.
    module CandidateKinds
      # In the order the report lists them.
      KINDS = %w[rewrite_new_indexes rewrite_same_indexes original_new_indexes].map(&:freeze).freeze

      # The labels QUAACK makes itself: a search and "none", or an index_build
      # combination key: top:<n>, combination, set_aside:<n>, or shared:<n>,
      # an index another candidate ranked (task 20261017-2).
      LABEL = /\A(?:original|rewrite_[1-9]\d*):(?:none|combination|(?:top|set_aside|shared):[1-9]\d*)\z/

      # The only labels candidate-runs may skip: a rewrite's shared pairing
      # (task 20261018-31).
      SKIPPABLE = /\Arewrite_[1-9]\d*:shared:[1-9]\d*\z/

      # What a report's labels fields hold when it doesn't have them.
      EMPTY = { "top" => [], "labels" => [], "excluded" => {} }.freeze

      module_function

      # The kind of a measured label such as "original:top:1" or
      # "rewrite_2:none", or nil for one that is no candidate ("original:none"
      # is the baseline itself).
      def of(label)
        search, key = label.to_s.split(":", 2)
        return key == "none" ? nil : "original_new_indexes" if search == "original"

        key == "none" ? "rewrite_same_indexes" : "rewrite_new_indexes"
      end

      def label?(label) = label.is_a?(String) && LABEL.match?(label)

      # Whether a report's fields carry only QUAACK's own labels: each
      # entry of top and of labels is a Hash whose label passes label?, and
      # each key of excluded does. Each entry of labels carries skipped, a
      # label candidate-runs didn't run (task 20261018-31), only as false,
      # or as true on a rewrite's shared pairing that neither timed out nor
      # has measurements (skipped?), if at all. A field the report doesn't have counts as
      # empty. Keys may be Strings or Symbols, as JSON writes either.
      def labels?(fields)
        top, labels, excluded = EMPTY.map { |key, empty| fields.fetch(key) { fields.fetch(key.to_sym, empty) } }
        entries?(top) && label_entries?(labels) &&
          excluded.is_a?(Hash) && excluded.keys.all? { label?(it.is_a?(Symbol) ? it.to_s : it) }
      end

      def label_entries?(labels) = entries?(labels) && labels.all? { skipped?(it) }

      # skipped absent or false, or true on a rewrite's shared pairing
      # (SKIPPABLE) that neither timed out nor carries measurements, under
      # either kind of key.
      def skipped?(entry)
        return true unless entry.key?("skipped") || entry.key?(:skipped)

        case field(entry, "skipped")
        when false then true
        when true then SKIPPABLE.match?(field(entry, "label")) && !both(entry, "timed_out").include?(true) &&
          both(entry, "measurements").all?(nil)
        else false
        end
      end

      def field(entry, key) = entry.fetch(key) { entry[key.to_sym] }

      # The values under key as a String and as a Symbol, since JSON writes either.
      def both(entry, key) = [entry[key], entry[key.to_sym]]

      # Whether a report's top carries kinds (valid?) and every label in it
      # is QUAACK's own (labels?), as the driver checks both.
      def report?(fields) = valid?(fields.fetch("top") { fields.fetch(:top, []) }) && labels?(fields)

      def entries?(entries)
        entries.is_a?(Array) &&
          entries.all? { |entry| entry.is_a?(Hash) && label?(entry.fetch("label") { entry[:label] }) }
      end

      # Whether top, as JSON reads it back, is an Array of Hashes that each
      # carry a kind from KINDS (a String key "kind").
      def valid?(top)
        top.is_a?(Array) && top.all? { it.is_a?(Hash) && KINDS.include?(it["kind"] || it[:kind]) }
      end

      private_class_method :entries?, :label_entries?, :skipped?, :field, :both
    end
  end
end
