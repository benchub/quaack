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
    # two queries on, nil or a count. Task 20261012-3 adds the enumerate
    # stage, which runs after a fuzz pass, and its worlds, how many small
    # databases it compared, nil or a count, and bound, the most rows of
    # every database it tried, nil or 0 to MAX_BOUND.
    #
    # A fuzz disproof's sizes go only to the store and the report: one
    # [schema, table, rows] triple per table the shrunk counterexample put
    # rows in. Table names are schema; rows is a count from 1 to MAX_SIZE,
    # which means MAX_SIZE or more: fuzz can put as many rows in a table as
    # a query constant (task 20261012-13), so a larger count could carry
    # one out. The rows themselves never leave the enclave.
    #
    #   FuzzResult.rewrite_test?("stage" => "fuzz", "trials" => 12)  # => true
    #   FuzzResult.rewrite_test?("stage" => "enumerate", "worlds" => 900, "bound" => 2)  # => true
    #   FuzzResult.sizes?([["public", "orders", 2]])                  # => true
    module FuzzResult
      # rewrite-test is the stage of a message from before task 20261012-4,
      # which ran ScenarioTests after the search.
      STAGES = %w[fuzz enumerate rewrite-test].map(&:freeze).freeze

      # Task 20261012-4: why the search couldn't test a rewrite, which then
      # goes on as passed with this as its rule, the report's caution, as
      # one out of time does (RewriteBudget::RULE): the queries read no
      # table, the comparison can't judge them (FETCH FIRST ... WITH TIES),
      # the session couldn't be set up, no world let both queries run, the
      # budget ran out while a kill was confirmed, the search failed on the
      # arena, or a spec turned fuzz off.
      NOT_TESTED = %w[no_tables not_comparable setup_failed no_world unconfirmed search_failed fuzz_off]
                   .map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      # The most rows a size says, meaning that many or more.
      MAX_SIZE = 5

      # Enumerate never puts more than 4 rows in a table, so a bound past 4
      # rows wouldn't be true of every database that size.
      MAX_BOUND = 4

      # A Postgres identifier is at most 63 bytes.
      MAX_NAME_BYTES = 63

      module_function

      def rewrite_test?(fields) = stage?(fields["stage"]) && counts?(fields)

      def stage?(stage) = stage.nil? || STAGES.include?(stage)

      def trials?(trials) = trials.nil? || count?(trials)

      def bound?(bound) = bound.nil? || (count?(bound) && bound <= MAX_BOUND)

      # Whether fields' trials and worlds are nil or counts, and its bound nil or 0 to MAX_BOUND.
      def counts?(fields) = trials?(fields["trials"]) && trials?(fields["worlds"]) && bound?(fields["bound"])

      # Whether each of a report's rewrites carries sizes, trials, worlds and
      # bound that pass, and a not_tested that's nil or on NOT_TESTED.
      def rewrites?(rewrites) = rewrites.all? { sizes?(it["sizes"]) && counts?(it) && not_tested?(it["not_tested"]) }

      def not_tested?(reason) = reason.nil? || NOT_TESTED.include?(reason)

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
