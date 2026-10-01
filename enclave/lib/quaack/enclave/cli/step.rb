# frozen_string_literal: true

module Quaack
  module Enclave
    class CLI
      # One subcommand's step. handler responds to call(input:, store:,
      # options:) and returns an Array of message Hashes. input is the
      # parsed stdin object if the step takes input (input: true), and nil
      # otherwise, so stdin is read only for such a step. store is the
      # Store for --run if the step needs a run (run: true), a new run's
      # Store if the step starts one (new_run: true), and nil otherwise.
      # options maps each option the step declares, as its name without the
      # dashes, to :value or :flag (see Arguments). required names the
      # options a call must give.
      #
      # A step that names a run without opening it (run_id: true) takes
      # --run too, but gets no Store. It gets the run ID, checked only for
      # its form, as run_id:, and the store base as store_base:. That's for
      # teardown, whose run may already be gone.
      #
      # A new run is made only once argv and stdin have been read and
      # checked, so a usage or bad_input refusal never makes one. It's
      # deleted again unless the call succeeds all the way through its done
      # line, so a failed call leaves no run behind, and none that holds
      # inputs the step went on to refuse.
      #
      # A step that reports progress while it works (progress: true) gets
      # progress:, which sends one Protocol::PROGRESS message through egress
      # at once (see CLI#progress).
      Step = Data.define(:handler, :input, :run, :new_run, :run_id, :options, :required, :progress) do
        def initialize(handler:, input: false, run: false, new_run: false, run_id: false, options: {}, required: [],
                       progress: false)
          raise ArgumentError, "a step can't both start a run and open one" if run && new_run
          raise ArgumentError, "a step that names a run can't also open or start one" if run_id && (run || new_run)

          undeclared = required - options.keys
          raise ArgumentError, "a step can't require an option it doesn't declare" unless undeclared.empty?

          super
        end
      end
    end
  end
end
