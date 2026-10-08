# frozen_string_literal: true

require_relative "enclave_error"

module Quaack
  module Driver
    # What Teardown prints to stderr. Each message names only the run ID,
    # which the driver already has, the run's jump host, which the
    # operator gave `quaack start`, and the enclave's shaped rule. The
    # enclave never sends the store's path, so a message builds the
    # default one from the ID. With the jump host, the teardown command is
    # one to run from the laptop, over ssh; without it, one to run on the
    # jump server.
    module TeardownMessages
      # The rules for a run's store the enclave wouldn't or couldn't delete.
      BY_HAND = %w[bad_run bad_store_base teardown_failed].freeze

      module_function

      def command(run_id, jump = nil)
        "#{"ssh #{jump} " if jump}quaacks teardown --run #{run_id}"
      end

      # How to run command: "run" followed by it, as in "run: <command>".
      def run(verb, run_id, jump) = "#{verb}#{" this on the jump server" unless jump}: #{command(run_id, jump)}"

      def later(run_id, jump) = "To tear it down later, #{run("run", run_id, jump)}"

      # What to do after a run kept since a setup step failed, or a signal
      # interrupted one.
      def resume_or_tear(run_id, jump)
        "resume with `quaack run --run #{run_id}`, or tear the run down by #{run("running", run_id, jump)}"
      end

      def kept(run_id, jump = nil) = "quaack: kept run #{run_id}. #{later(run_id, jump)}\n"

      # A run kept since a setup step failed, or a signal interrupted one.
      # After a signal, quaack run prints no failure line, so this says
      # what to do next.
      def kept_after_setup(run_id, jump, signal)
        return "quaack: kept run #{run_id}, since a setup step failed.\n" unless signal

        "quaack: kept run #{run_id}, since a signal interrupted a setup step. " \
          "To go on, #{resume_or_tear(run_id, jump)}\n"
      end

      def skipped(run_id, jump)
        "quaack: skipped the teardown of run #{run_id}, since ssh to the jump server failed. " \
          "#{later(run_id, jump)}\n"
      end

      def done(run_id, next_step)
        return "quaack: deleted the store for run #{run_id}, and destroyed its run server.\n" if next_step == "none"

        "quaack: deleted the store for run #{run_id}. Destroy the run server for run #{run_id} now.\n"
      end

      def interrupted(run_id, jump, run_error)
        finish = "#{later(run_id, jump)}\n"
        return "quaack: a signal interrupted the teardown of run #{run_id}. #{finish}" unless run_error

        what = run_error.is_a?(EnclaveError) ? run_error.rule : "#{run_error.class}: #{run_error.message}"
        "quaack: run #{run_id} failed (#{what}), and a signal interrupted its teardown. #{finish}"
      end

      def failed(run_id, jump, rule)
        hint = if rule == "destroy_command_not_run"
                 "destroy_command didn't run, so destroy the run server for run #{run_id} yourself. Then check " \
                   "or remove ~/.quaack/runs/#{run_id} on the jump server by hand."
               elsif BY_HAND.include?(rule)
                 "Check or remove ~/.quaack/runs/#{run_id} on the jump server by hand."
               else
                 later(run_id, jump)
               end
        "quaack: couldn't tear down run #{run_id} (#{rule}). #{hint}\n"
      end
    end
  end
end
