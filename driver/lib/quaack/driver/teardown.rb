# frozen_string_literal: true

require_relative "enclave_error"

module Quaack
  module Driver
    # Runs `quaacks teardown --run <id>` when a run ends, however it ends
    # (DESIGN.md, "Where QUAACK runs"):
    #
    #   Teardown.around(transport:, run_id:, stderr:, keep: false) { ... }
    #   # => the block's value
    #
    # It tears down in an ensure, so a run that succeeds, aborts, or raises
    # is torn down. Ruby's default INT and TERM handlers raise Interrupt and
    # SignalException, which unwind through that ensure too, and the signal
    # then goes on to end the process as usual. A teardown that fails never
    # masks the run's own error: it prints its operator message, and raises
    # its error only when the run itself succeeded. With keep, it skips
    # teardown and prints the command to run later.
    #
    # A signal during teardown, such as a second Ctrl-C, still ends the
    # process: its SignalException goes on and replaces the run's error. So
    # first it prints the run's error, if the run failed (only the rule of
    # an EnclaveError), and the command that finishes teardown. Ruby prints
    # nothing for an uncaught SIGTERM, so without that line the run's error
    # would be lost.
    #
    # Messages go to stderr and name only the run ID, which the driver
    # already has, and the enclave's shaped rule. The enclave never sends
    # the store's path, so the message builds the default one from the ID.
    class Teardown
      # The rules for a run's store the enclave wouldn't or couldn't delete.
      BY_HAND = %w[bad_run bad_store_base teardown_failed].freeze

      def self.around(transport:, run_id:, stderr:, keep: false)
        run_error = nil
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- only noted, then re-raised
        # Captured here, not read from $ERROR_INFO in the ensure: that would
        # be the caller's error when around is called inside a rescue.
        run_error = e
        raise
      ensure
        keep ? stderr.print(kept(run_id)) : new(transport, run_id, stderr).finish(run_error)
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

      # Tears down, and raises the teardown's error only when the run itself
      # succeeded, so it never masks the run's own error.
      def finish(run_error)
        error = call(run_error)
        raise error if error && !run_error
      end

      # nil once the store is gone, or the error that says why not: the
      # transport's EnclaveError, or any other StandardError, whose rule is
      # then driver_error. run_error is the run's own error, or nil. A
      # signal isn't a StandardError, so it goes on, after its message.
      def call(run_error = nil)
        line = @transport.call("teardown", args: { run: @run_id }).messages.find { it["type"] == "teardown" }
        raise EnclaveError.new(subcommand: "teardown", rule: "no_teardown") unless line

        @stderr.print done(line["next_step"])
        nil
      rescue StandardError => e
        @stderr.print failed(e.is_a?(EnclaveError) ? e.rule : "driver_error")
        e
      rescue SignalException
        @stderr.print interrupted(run_error)
        raise
      end

      private

      def done(next_step)
        return "quaack: deleted the store for run #{@run_id}, and destroyed its run server.\n" if next_step == "none"

        "quaack: deleted the store for run #{@run_id}. Destroy the run server for run #{@run_id} now.\n"
      end

      def interrupted(run_error)
        finish = "Run this on the jump server: #{self.class.command(@run_id)}\n"
        return "quaack: a signal interrupted the teardown of run #{@run_id}. #{finish}" unless run_error

        what = run_error.is_a?(EnclaveError) ? run_error.rule : "#{run_error.class}: #{run_error.message}"
        "quaack: run #{@run_id} failed (#{what}), and a signal interrupted its teardown. #{finish}"
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
