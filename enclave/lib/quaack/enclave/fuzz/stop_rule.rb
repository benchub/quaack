# frozen_string_literal: true

require "quaack/protocol/fuzz_result"

module Quaack
  module Enclave
    module Fuzz
      # When the fuzz search stops (task 20261012-2, the user's rule): it
      # runs at least floor; past it, it stops once it has run twice as long
      # as it took to find its last new coverage signature (Signature); it
      # never runs past cap. Fuzz.run stops at once on a lifted
      # counterexample, and the rewrite's Deadline bounds it too, since
      # every trial checks it.
      #
      #   rule = StopRule.from_env(ENV)
      #   rule.observe(signature) until rule.stop?
      #
      # The units are seconds on the monotonic clock in production: a floor
      # of 30 and a cap of 60 (task 20261012-35), so the search never runs
      # past 60 seconds, nor past the rewrite's five-minute Deadline, and
      # leaves enumerate its time. For specs, QUAACKS_FUZZ_TRIALS=<n> makes
      # each observed trial one unit, with a floor of n trials and a cap of
      # CAP_FLOORS times that, so the search does the same work on any
      # machine and a spec's verdict never depends on its speed.
      # QUAACKS_FUZZ_TRIALS=0 turns the search off. When it's set, the
      # rewrite's fuzz record in the burndown says so
      # (Steps::RewriteFuzz::SETTINGS).
      #
      # stopped says why the search stopped and when, for the report (task
      # 20261016-4, Protocol::FuzzResult.stop?): the rule's own reason, or
      # the one the search names (a deadline, kills that didn't lift), in
      # whole seconds. Counting trials, its reason is trials, and it gives
      # no times, so a spec's outcome is the same on any machine.
      class StopRule
        ENV_TRIALS = "QUAACKS_FUZZ_TRIALS"
        FLOOR_SECONDS = 30
        CAP_SECONDS = 60
        CAP_FLOORS = 10
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        attr_reader :floor, :cap, :unit, :trials

        # The rule ENV asks for, or nil when QUAACKS_FUZZ_TRIALS is 0, which
        # turns the search off, for the specs that don't test it.
        def self.from_env(env)
          value = env[ENV_TRIALS]
          return new(floor: FLOOR_SECONDS, cap: CAP_SECONDS, clock: MONOTONIC) if value.nil?
          raise ArgumentError, "#{ENV_TRIALS} must be a whole number" unless value.match?(/\A(0|[1-9]\d*)\z/)

          trials(Integer(value)) unless value == "0"
        end

        def self.trials(floor) = new(floor:, cap: floor * CAP_FLOORS, clock: nil)

        # clock gives the time in seconds; nil counts observed trials instead.
        def initialize(floor:, cap:, clock:)
          @floor = floor
          @cap = cap
          @clock = clock
          @unit = clock ? :seconds : :trials
          @start = now
          @trials = 0
          @seen = Set.new
          @last_new = 0
        end

        # One trial's signature, after the trial.
        def observe(signature)
          @trials += 1
          @last_new = elapsed if @seen.add?(signature)
        end

        def elapsed = now - @start

        def stop?
          spent = elapsed
          return true if cap && spent >= cap

          spent >= floor && spent >= 2 * @last_new
        end

        # Why the search stopped, why if it names its own reason, and when,
        # as Protocol::FuzzResult's fuzz_stop.
        def stopped(why = nil)
          return { "reason" => why || "trials", "seconds" => nil, "quiet" => nil } if unit == :trials

          spent = elapsed
          seconds = whole(spent)
          { "reason" => why || ruled(spent), "seconds" => seconds, "quiet" => [whole(spent - @last_new), seconds].min }
        end

        private

        def ruled(spent)
          return "cap" if cap && spent >= cap

          2 * @last_new > floor ? "dry" : "floor"
        end

        def whole(seconds) = seconds.round.clamp(0, Protocol::FuzzResult::MAX_STOP_SECONDS)

        def now = @clock ? @clock.call : @trials.to_i
      end
    end
  end
end
