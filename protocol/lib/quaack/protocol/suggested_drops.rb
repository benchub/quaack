# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of a report label's suggested_drops (DESIGN.md's index-dedupe
    # and report): the existing indexes that the label's new indexes make
    # redundant, which QUAACK only suggests dropping. Each is { "name",
    # "size_bytes", "idx_scan" }: an index name, which is schema and which
    # the report names elsewhere too, its size in bytes, and the scan count
    # production's pg_stat_user_indexes holds for it. Either count may be
    # nil when the enclave couldn't read it. Nothing else goes out, never a
    # definition or a predicate.
    module SuggestedDrops
      KEYS = %w[idx_scan name size_bytes].map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**15

      # A Postgres identifier is at most 63 bytes.
      MAX_NAME_BYTES = 63

      module_function

      # Whether list, as JSON reads it back, is an Array of exactly KEYS
      # Hashes: name a String of at most MAX_NAME_BYTES bytes, and each count
      # nil or an Integer from zero up to below MAX_COUNT. The one check on
      # what a label may carry here, for the enclave's egress function and
      # the driver both.
      def valid?(list) = list.is_a?(Array) && list.all? { entry?(it) }

      def entry?(entry)
        entry.is_a?(Hash) && entry.keys.all?(String) && entry.keys.sort == KEYS &&
          entry["name"].is_a?(String) && entry["name"].bytesize <= MAX_NAME_BYTES &&
          %w[size_bytes idx_scan].all? { count?(entry[it]) }
      end

      def count?(value) = value.nil? || (value.is_a?(Integer) && value.between?(0, MAX_COUNT - 1))
    end
  end
end
