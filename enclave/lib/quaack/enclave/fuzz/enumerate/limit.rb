# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      module Enumerate
        # How long enumerate runs after a fuzz pass (task 20261012-3, the
        # user's rule): WORLDS worlds tried in production (task
        # 20261010-47), so the bound it reports is fixed by the worlds'
        # order and never follows how long each takes, with SECONDS on the
        # monotonic clock as a backstop (timed_out?), inside the rewrite's
        # Deadline. A run the backstop or the Deadline stops reports no bound. For specs, QUAACKS_ENUMERATE_WORLDS=<n>
        # caps it at n worlds tried instead, so a spec's verdict never
        # depends on the machine's speed, and 0 turns it off, as
        # QUAACKS_FUZZ_TRIALS does the fuzz search (StopRule). When it's set,
        # the rewrite's fuzz record in the burndown says so
        # (Steps::RewriteFuzz::SETTINGS).
        #
        #   limit = Limit.from_env(ENV)
        #   started = limit.start
        #   limit.over?(tried, started)
        Limit = Data.define(:cap, :clock)

        class Limit
          ENV_WORLDS = "QUAACKS_ENUMERATE_WORLDS"
          WORLDS = 8192
          SECONDS = 30
          MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

          def self.from_env(env)
            value = env[ENV_WORLDS]
            return new(cap: WORLDS, clock: MONOTONIC) if value.nil?
            raise ArgumentError, "#{ENV_WORLDS} must be a whole number" unless value.match?(/\A(0|[1-9]\d*)\z/)

            worlds(Integer(value)) unless value == "0"
          end

          def self.worlds(cap) = new(cap:, clock: nil)

          def start = clock&.call

          def over?(tried, started) = tried >= cap || timed_out?(started)

          def timed_out?(started) = !clock.nil? && clock.call - started >= SECONDS
        end
      end
    end
  end
end
