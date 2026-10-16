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

      # Task 20261016-4: why the fuzz search stopped, in the report's
      # fuzz_stop: its stop rule's minimum ran out with nothing new (floor),
      # or it had run twice as long as it took to find its last new plan
      # behaviour (dry), or it reached its cap, or the rewrite's deadline,
      # or LIFTS kills that didn't lift, or a spec's trial count
      # (QUAACKS_FUZZ_TRIALS) stopped it.
      STOP_REASONS = %w[dry floor cap deadline unlifted trials].map(&:freeze).freeze

      # No search runs this long: the rewrite's whole budget is 300 seconds.
      MAX_STOP_SECONDS = 3600

      STOP_KEYS = %w[reason seconds quiet].map(&:freeze).freeze

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
      # bound that pass, a not_tested that's nil or on NOT_TESTED, and a
      # fuzz_stop that stop? passes.
      def rewrites?(rewrites)
        rewrites.all? do |rewrite|
          sizes?(rewrite["sizes"]) && counts?(rewrite) && not_tested?(rewrite["not_tested"]) &&
            stop?(rewrite["fuzz_stop"])
        end
      end

      # Whether stop is nil or why fuzz stopped (task 20261016-4): exactly a
      # reason on STOP_REASONS, seconds, nil (a spec's trial count) or a
      # whole number up to MAX_STOP_SECONDS, and quiet, nil or whole
      # seconds up to seconds, how long it had found no new plan behaviour.
      def stop?(stop)
        return true if stop.nil?
        return false unless stop.is_a?(Hash) && stop.size == STOP_KEYS.size && STOP_KEYS.all? { stop.key?(it) }

        reason, seconds, quiet = stop.values_at(*STOP_KEYS)
        STOP_REASONS.include?(reason) && times?(seconds, quiet)
      end

      # Whether seconds and quiet are both nil, or whole seconds, quiet nil or no more than seconds.
      def times?(seconds, quiet)
        return quiet.nil? if seconds.nil?

        seconds?(seconds) && (quiet.nil? || (seconds?(quiet) && quiet <= seconds))
      end

      def seconds?(seconds) = count?(seconds) && seconds <= MAX_STOP_SECONDS

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

      private_class_method :size?, :name?, :count?, :times?, :seconds?
    end
  end
end
