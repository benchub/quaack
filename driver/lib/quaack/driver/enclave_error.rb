# frozen_string_literal: true

module Quaack
  module Driver
    # A call to the enclave script that failed (see Transport). It carries
    # only what the driver can trust to be shape-class data: the subcommand
    # the driver asked for, the step, rule, and SQLSTATE from the enclave's
    # error line (each checked for shape, and nil if it's missing or not
    # shaped), and how the process ended. It never carries the process's
    # output, and it's raised with no cause.
    #
    # rule is the error line's rule, or one of the driver's own:
    #
    # - incomplete: no error line, and the run didn't end with its done
    #   line, exit 0, and no signal. A step that called exit!, a process
    #   killed by SIGKILL, and an ssh session that couldn't connect all end
    #   up here.
    # - unexpected_output: the run printed a line the driver refuses, such
    #   as a message of a type or with a field not on the protocol's
    #   whitelist, so the two sides disagree on the protocol.
    # - timeout: the run took longer than the transport's timeout, so the
    #   driver killed it.
    # - output_too_large: the run printed more than the transport reads, so
    #   the driver killed it.
    class EnclaveError < StandardError
      # sysexits.h's EX_USAGE and EX_SOFTWARE, as the enclave's CLI uses
      # them: the CLI refused the call, or a step failed.
      EX_USAGE = 64
      EX_SOFTWARE = 70

      attr_reader :subcommand, :rule, :step, :sqlstate, :function, :exit_status, :signal

      # exit_status is the process's exit status, or nil if a signal ended
      # it. signal is that signal's name, such as "TERM", or nil.
      def initialize(subcommand:, rule:, step: nil, sqlstate: nil, function: nil, exit_status: nil, signal: nil) # rubocop:disable Metrics/ParameterLists
        @subcommand = subcommand
        @rule = rule
        @step = step
        @sqlstate = sqlstate
        @function = function
        @exit_status = exit_status
        @signal = signal
        super(describe)
      end

      # The CLI refused the call, as for an unknown subcommand or option.
      def usage? = exit_status == EX_USAGE

      # The step ran and failed.
      def step_failed? = exit_status == EX_SOFTWARE

      # A signal ended the process.
      def killed? = !signal.nil?

      private

      def describe
        details = [("step #{step}" if step), ("SQLSTATE #{sqlstate}" if sqlstate),
                   ("function #{function}" if function),
                   ("exit #{exit_status}" if exit_status), ("signal #{signal}" if signal)].compact
        "quaacks #{subcommand} failed: #{rule}#{" (#{details.join(", ")})" unless details.empty?}"
      end
    end
  end
end
