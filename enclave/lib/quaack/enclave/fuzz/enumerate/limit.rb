# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      module Enumerate
        # How long enumerate runs after a fuzz pass (task 20261012-3, the
        # user's rule): SECONDS on the monotonic clock in production, inside
        # the rewrite's Deadline. For specs, QUAACKS_ENUMERATE_WORLDS=<n>
        # caps it at n worlds tried instead, so a spec's verdict never
        # depends on the machine's speed, and 0 turns it off, as
        # QUAACKS_FUZZ_TRIALS does the fuzz search (StopRule).
        #
        #   limit = Limit.from_env(ENV)
        #   started = limit.start
        #   limit.over?(tried, started)
        Limit = Data.define(:cap, :clock)

        class Limit
          ENV_WORLDS = "QUAACKS_ENUMERATE_WORLDS"
          SECONDS = 30
          MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

          def self.from_env(env)
            value = env[ENV_WORLDS]
            return new(cap: SECONDS, clock: MONOTONIC) if value.nil?
            raise ArgumentError, "#{ENV_WORLDS} must be a whole number" unless value.match?(/\A(0|[1-9]\d*)\z/)

            worlds(Integer(value)) unless value == "0"
          end

          def self.worlds(cap) = new(cap:, clock: nil)

          def start = clock&.call

          def over?(tried, started) = clock ? clock.call - started >= cap : tried >= cap
        end
      end
    end
  end
end
