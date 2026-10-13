# frozen_string_literal: true

module Quaack
  module Protocol
    # What rewrite-test's fuzz search (task 20261012-2, DESIGN.md's
    # rewrite-test) adds to what leaves the enclave, checked by the
    # enclave's egress function and the driver both.
    #
    # A rewrite_test message's stage is the stage that decided it, nil (a
    # rewrite plan-pruning discarded, which nothing tested) or one of
    # STAGES, and trials how many small random databases fuzz compared the
    # two queries on, nil or a count.
    #
    # A fuzz disproof's sizes go only to the store and the report: one
    # [schema, table, rows] triple per table the shrunk counterexample put
    # rows in. Table names are schema; rows is a count from 1 to MAX_SIZE,
    # which means MAX_SIZE or more: fuzz can put as many rows in a table as
    # a query constant (task 20261012-13), so a larger count could carry
    # one out. The rows themselves never leave the enclave.
    #
    #   FuzzResult.rewrite_test?("stage" => "fuzz", "trials" => 12)  # => true
    #   FuzzResult.sizes?([["public", "orders", 2]])                  # => true
    module FuzzResult
      STAGES = %w[fuzz rewrite-test].map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      # The most rows a size says, meaning that many or more.
      MAX_SIZE = 5

      # A Postgres identifier is at most 63 bytes.
      MAX_NAME_BYTES = 63

      module_function

      def rewrite_test?(fields) = stage?(fields["stage"]) && trials?(fields["trials"])

      def stage?(stage) = stage.nil? || STAGES.include?(stage)

      def trials?(trials) = trials.nil? || count?(trials)

      # Whether each of a report's rewrites carries sizes and trials that pass.
      def rewrites?(rewrites) = rewrites.all? { sizes?(it["sizes"]) && trials?(it["trials"]) }

      def sizes?(sizes)
        return true if sizes.nil?

        sizes.is_a?(Array) && sizes.all? { size?(it) } && sizes.map { it.take(2) }.uniq.size == sizes.size
      end

      def size?(size)
        size.is_a?(Array) && size.size == 3 && size.take(2).all? { name?(it) } && count?(size[2]) &&
          size[2].between?(1, MAX_SIZE)
      end

      def name?(name) = name.is_a?(String) && !name.empty? && name.bytesize <= MAX_NAME_BYTES

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :size?, :name?, :count?
    end
  end
end
