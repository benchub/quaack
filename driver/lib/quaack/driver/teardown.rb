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
    # teardown and prints the command to run later. It skips it the same
    # way after a run that failed as ssh_failed: ssh is down, so the call
    # would only fail too, after another connect timeout and probe.
    #
    # A signal during teardown, such as a second Ctrl-C, still ends the
    # process: its SignalException goes on and replaces the run's error. So
    # first it prints the run's error, if the run failed (only the rule of
    # an EnclaveError), and the command that finishes teardown. Ruby prints
    # nothing for an uncaught SIGTERM, so without that line the run's error
    # would be lost. A signal in the instant after the transport returns,
    # while a failure message prints or before around ends, still replaces
    # the run's error without that line. Closing it would mean masking
    # signals, which isn't worth the complexity for so small a window.
    #
    # Messages go to stderr and name only the run ID, which the driver
    # already has, and the enclave's shaped rule. The enclave never sends
    # the store's path, so the message builds the default one from the ID.
    class Teardown
      # The rules for a run's store the enclave wouldn't or couldn't delete.
      BY_HAND = %w[bad_run bad_store_base teardown_failed].freeze

      def self.around(transport:, run_id:, stderr:, keep: false, &)
        new(transport, run_id, stderr).around(keep:, &)
      end

      # What to do after a failed run whose store teardown deleted.
      START_OVER = "start a new run with `quaack start`"

      def self.command(run_id) = "quaacks teardown --run #{run_id}"

      # What to do after `quaack run --run <run_id>` failed: resume it
      # while its store is left, or start a new run once teardown deleted
      # it. When the run itself succeeded and only its teardown failed,
      # resuming would redo the run's last steps, so it says to tear down.
      # teardown is the run's Teardown, or nil if the run failed before it
      # had one.
      def self.next_step(teardown, run_id)
        return START_OVER if teardown&.deleted?
        return "tear the run down with `#{command(run_id)}` on the jump server (the run itself finished)" if
          teardown&.only_teardown_left?

        "resume with `quaack run --run #{run_id}`"
      end

      def self.kept(run_id)
        "quaack: kept run #{run_id}. To tear it down later, run this on the jump server: #{command(run_id)}\n"
      end

      attr_reader :transport

      def initialize(transport, run_id, stderr)
        @transport = transport
        @run_id = run_id
        @stderr = stderr
        @deleted = false
        @only_teardown_left = false
      end

      # As self.around, for a caller that then asks deleted?.
      def around(keep: false)
        run_error = nil
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- only noted, then re-raised
        # Captured here, not read from $ERROR_INFO in the ensure: that would
        # be the caller's error when around is called inside a rescue.
        run_error = e
        raise
      ensure
        if keep then @stderr.print(self.class.kept(@run_id))
        elsif ssh_failed?(run_error) then @stderr.print(skipped)
        else finish(run_error)
        end
      end

      # Whether teardown deleted the run's store, so there's nothing left
      # to resume. It's false with keep, after a skipped or failed
      # teardown, and before teardown runs.
      def deleted? = @deleted

      # Whether the run succeeded and then its teardown failed.
      def only_teardown_left? = @only_teardown_left

      # Tears down, and raises the teardown's error only when the run itself
      # succeeded, so it never masks the run's own error.
      def finish(run_error)
        error = call(run_error)
        return unless error && !run_error

        @only_teardown_left = true
        raise error
      end

      # nil once the store is gone, or the error that says why not: the
      # transport's EnclaveError, or any other error, whose rule is then
      # driver_error. That includes errors outside StandardError, such as a
      # LoadError, so they can't mask the run's own error either. run_error
      # is the run's own error, or nil. A signal goes on, after its message.
      def call(run_error = nil)
        @stderr.print done(teardown_line["next_step"])
        @deleted = true
        nil
      rescue SignalException
        @stderr.print interrupted(run_error)
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException -- returned, not swallowed; signals go on above
        @stderr.print failed(e.is_a?(EnclaveError) ? e.rule : "driver_error")
        e
      end

      private

      def teardown_line
        line = @transport.call("teardown", args: { run: @run_id }).messages.find { it["type"] == "teardown" }
        line or raise EnclaveError.new(subcommand: "teardown", rule: "no_teardown")
      end

      def ssh_failed?(run_error) = run_error.is_a?(EnclaveError) && run_error.rule == "ssh_failed"

      def skipped
        "quaack: skipped the teardown of run #{@run_id}, since ssh to the jump server failed. #{later}\n"
      end

      def later = "To tear it down later, run this on the jump server: #{self.class.command(@run_id)}"

      def done(next_step)
        return "quaack: deleted the store for run #{@run_id}, and destroyed its run server.\n" if next_step == "none"

        "quaack: deleted the store for run #{@run_id}. Destroy the run server for run #{@run_id} now.\n"
      end

      def interrupted(run_error)
        finish = "#{later}\n"
        return "quaack: a signal interrupted the teardown of run #{@run_id}. #{finish}" unless run_error

        what = run_error.is_a?(EnclaveError) ? run_error.rule : "#{run_error.class}: #{run_error.message}"
        "quaack: run #{@run_id} failed (#{what}), and a signal interrupted its teardown. #{finish}"
      end

      def failed(rule)
        hint = if BY_HAND.include?(rule)
                 "Check or remove ~/.quaack/runs/#{@run_id} on the jump server by hand."
               else
                 later
               end
        "quaack: couldn't tear down run #{@run_id} (#{rule}). #{hint}\n"
      end
    end
  end
end
