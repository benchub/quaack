# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of the report's winner_timing (DESIGN.md's winner-timing and
    # report): how the one timed EXPLAIN ANALYZE of the winner on the slow
    # values went, as one of QUAACK's own words. timed: its times are in the
    # winner's measured plan. timed_out: it hit statement_timeout.
    # failed: it raised some other error. plan_differs: it ran, but its
    # plan's steps aren't the measured plan's, so no time is shown. nil:
    # there's no winner, or the run's store is from before winner-timing.
    module WinnerTiming
      RESULTS = %w[timed timed_out failed plan_differs].map(&:freeze).freeze

      module_function

      # Whether field, as JSON reads it back, is nil or a String in
      # RESULTS. The one check on what it may carry, for the enclave's
      # egress function and the driver both.
      def valid?(field) = field.nil? || (field.is_a?(String) && RESULTS.include?(field))
    end
  end
end
