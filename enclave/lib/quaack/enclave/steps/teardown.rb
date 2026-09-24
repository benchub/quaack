# frozen_string_literal: true

require_relative "../store/teardown"

module Quaack
  module Enclave
    module Steps
      # `quaacks teardown --run <run ID>` (README, "Where QUAACK runs"):
      # deletes the run's governed store directory when the run ends, and
      # reminds the operator to destroy the run server, which the enclave
      # can't do itself. The driver runs it at the end of every run, whether
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

        module_function

        def call(run_id:, store_base:, **)
          result = Store.teardown(run_id, base: store_base)
          [{ type: :teardown, run_id:, store: result, next_step: NEXT_STEP }]
        rescue Store::BadRun
          raise Error, "bad_run", cause: nil
        rescue Store::BadBase
          raise Error, "bad_store_base", cause: nil
        rescue Store::Error
          raise Error, "teardown_failed", cause: nil
        end
      end
    end
  end
end
