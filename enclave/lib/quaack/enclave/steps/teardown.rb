# frozen_string_literal: true

require_relative "../store/teardown"
require_relative "../config"
require_relative "../run_server_command"

module Quaack
  module Enclave
    module Steps
      # `quaacks teardown --run <run ID>` (README, "Where QUAACK runs"):
      # deletes the run's governed store directory when the run ends. With
      # destroy_command in the quaacks config, it first destroys the run
      # server with it (see RunServerCommand), and a failure there,
      # destroy_command_failed or destroy_command_timed_out, keeps the store
      # so teardown can run again. Without one, it reminds the operator to
      # destroy the run server. The driver runs it at the end of every run, whether
      # it succeeded or aborted. After a run kept for debugging, the operator
      # runs it by hand.
      #
      # The CLI checks the run ID's form but doesn't open the run (run_id:
      # true), since a run that's already gone is torn down too: it prints
      # already_gone and succeeds, so running teardown twice is safe.
      #
      # Its one line is shape only: the run ID, which the call gave and the
      # CLI checked, and two of this file's constants. A failure is an Error
      # with only its rule:
      #
      # - bad_run: something is at the run's path, but it isn't a run
      #   directory Store.open would open, such as a symlink, which could
      #   point out of the store. It's left alone.
      # - bad_store_base: it can't look in the store's base, such as one
      #   that's a file or sits under a directory it can't search, or the
      #   base is a symlink or sits in one (Store::LINKED_BASE).
      # - teardown_failed: deleting the directory failed partway, and the
      #   directory is still there. A run another call deleted first is
      #   already_gone, not a failure.
      module Teardown
        # A failed teardown. It names only its rule, and has no cause, since
        # a Store::Error names the run's directory.
        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        NEXT_STEP = "destroy_run_server"
        # What's left once destroy_command has destroyed the run server.
        NOTHING_LEFT = "none"

        module_function

        def call(run_id:, store_base:, **)
          destroyed = destroyed?(run_id, store_base)
          result = Store.teardown(run_id, base: store_base)
          [{ type: :teardown, run_id:, store: result, next_step: destroyed ? NOTHING_LEFT : NEXT_STEP }]
        rescue Store::BadRun
          raise Error, "bad_run", cause: nil
        rescue Store::BadBase
          raise Error, "bad_store_base", cause: nil
        rescue Store::Error
          raise Error, "teardown_failed", cause: nil
        end

        # Runs the configured destroy_command for a run that's still there,
        # before its store goes, since the command is given the run's server.
        # Whether it ran. A run that's gone, or isn't one, is left to
        # Store.teardown, and its run server to the operator.
        def destroyed?(run_id, store_base)
          command = Config.load.destroy_command
          store = open_run(run_id, store_base) if command
          return false unless store

          server = store.entry?("server") ? store.read("server") : ""
          RunServerCommand.destroy(command, server:, run: run_id)
          true
        end

        def open_run(run_id, store_base)
          Store.open(run_id, base: store_base)
        rescue Store::Error
          nil
        end
      end
    end
  end
end
