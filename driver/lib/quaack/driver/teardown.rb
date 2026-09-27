# frozen_string_literal: true

require_relative "enclave_error"

module Quaack
  module Driver
    # Runs `quaacks teardown --run <id>` when a run ends, however it ends
    # (README, "Where QUAACK runs"):
    #
    #   Teardown.around(transport:, run_id:, stderr:, keep: false) { ... }
    #   # => the block's value
    #
    # It tears down in an ensure, so a run that succeeds, aborts, or raises
    # is torn down. Ruby's default INT and TERM handlers raise Interrupt and
    # SignalException, which unwind through that ensure too, and the signal
    # then goes on to end the process as usual. A teardown that fails never
    # masks the run's own error: it prints its operator message, and raises
    # its EnclaveError only when the run itself succeeded. With keep, it
    # skips teardown and prints the command to run later.
    #
    # Messages go to stderr and name only the run ID, which the driver
    # already has, and the enclave's shaped rule. The enclave never sends
    # the store's path, so the message builds the default one from the ID.
    class Teardown
      # The rules for a run's store the enclave wouldn't or couldn't delete.
      BY_HAND = %w[bad_run bad_store_base teardown_failed].freeze

      def self.around(transport:, run_id:, stderr:, keep: false)
        error = nil
        begin
          result = yield
        ensure
          keep ? stderr.print(kept(run_id)) : (error = new(transport, run_id, stderr).call)
        end
        raise error if error

        result
      end

      def self.command(run_id) = "quaacks teardown --run #{run_id}"

      def self.kept(run_id)
        "quaack: kept run #{run_id}. To tear it down later, run this on the jump server: #{command(run_id)}\n"
      end

      def initialize(transport, run_id, stderr)
        @transport = transport
        @run_id = run_id
        @stderr = stderr
      end

      # nil once the store is gone, or the EnclaveError that says why not.
      def call
        line = @transport.call("teardown", args: { run: @run_id }).messages.find { it["type"] == "teardown" }
        raise EnclaveError.new(subcommand: "teardown", rule: "no_teardown") unless line

        @stderr.print done(line["next_step"])
        nil
      rescue EnclaveError => e
        @stderr.print failed(e.rule)
        e
      end

      private

      def done(next_step)
        return "quaack: deleted the store for run #{@run_id}, and destroyed its run server.\n" if next_step == "none"

        "quaack: deleted the store for run #{@run_id}. Destroy the run server for run #{@run_id} now.\n"
      end

      def failed(rule)
        hint = if BY_HAND.include?(rule)
                 "Check or remove ~/.quaack/runs/#{@run_id} on the jump server by hand."
               else
                 "Run this on the jump server: #{self.class.command(@run_id)}"
               end
        "quaack: couldn't tear down run #{@run_id} (#{rule}). #{hint}\n"
      end
    end
  end
end
