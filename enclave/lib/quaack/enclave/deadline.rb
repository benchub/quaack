# frozen_string_literal: true

require "quaack/protocol/rewrite_budget"

module Quaack
  module Enclave
    # A wall-clock budget, for rewrite-test's per-rewrite limit (task
    # 20261010-53, Protocol::RewriteBudget).
    #
    #   deadline = Deadline.new                 # five minutes from now
    #   Deadline.within(deadline) { Fuzz.search(...) }
    #
    # Code that can run long checks Deadline.check! (the block's deadline, or
    # none outside one): ArenaRunner before each statement, so between
    # loads and queries too, and the search between its trials. A check past the deadline
    # raises Expired. An ArenaRunner transaction rolls back however its
    # block ends, so an Expired leaves the arena as it was. The caller
    # (Steps::RewriteFuzz) catches it and reports the
    # rewrite as out of time.
    class Deadline
      SECONDS = Protocol::RewriteBudget::SECONDS
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      KEY = :quaack_enclave_deadline

      # The budget ran out. Its message is fixed, never a value.
      class Expired < StandardError
        def initialize(message = "the rewrite's time budget ran out") = super
      end

      def initialize(seconds = SECONDS, clock: MONOTONIC)
        @clock = clock
        @at = clock.call + seconds
      end

      def check!
        raise Expired if @clock.call >= @at
      end

      def self.within(deadline)
        previous = Thread.current[KEY]
        Thread.current[KEY] = deadline
        yield
      ensure
        Thread.current[KEY] = previous
      end

      def self.check! = Thread.current[KEY]&.check!
    end
  end
end
