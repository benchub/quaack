# frozen_string_literal: true

require_relative "egress"
require_relative "error_filter"
require_relative "store"
require_relative "cli/refused"
require_relative "cli/step"
require_relative "cli/bad_store_base"
require_relative "cli/arguments"
require_relative "cli/input"
require_relative "cli/output"
require_relative "cli/steps"

module Quaack
  module Enclave
    # The quaacks command line (README, "Where QUAACK runs"). The driver
    # calls it over ssh as `quaacks <subcommand> [options]`, with any larger
    # input as one JSON object on stdin. Each call runs one step and ends:
    # a step reads what it needs from the governed store, does its work,
    # writes new state back, and returns its messages. Nothing stays in
    # memory between calls.
    #
    # Everything on stdout goes through the egress function, one JSON line
    # per message, errors included. A step never writes: it returns an
    # Array of message Hashes, and the CLI sends each through
    # Egress.serialize, printing nothing for one it drops. It sends them
    # only once the step has returned and every one of them has been
    # written, so a step that fails prints only its error line. A step that
    # succeeds ends with DONE, so the driver can tell it from a process
    # that died without a word.
    #
    # Stderr goes back over ssh too, so main silences it, and main points
    # stdout's file descriptor at the null device, keeping a private copy
    # for the CLI. So a stray puts, print, or warn in a step, a child
    # process's output, and Ruby's own warnings all go nowhere.
    #
    # Exit statuses: 0 on success; 64 (EX_USAGE) when the CLI refuses the
    # call (see Refused); 70 (EX_SOFTWARE) when a step fails, including
    # when it calls exit or abort (see call_step); and death by
    # the signal for a signal, after its error line (see ErrorFilter.guard).
    class CLI
      # STEPS, each subcommand and its step, is in cli/steps.rb.

      # Other names for a subcommand.
      ALIASES = { "--version" => "version" }.freeze

      # The step error lines name when argv names no step. argv itself is
      # never echoed.
      CLI_STEP = "cli"

      # A step called exit or abort (see call_step).
      class StepExited < StandardError; end

      # The last line of the step's buffered output. A refused or failed step
      # never prints it. But if the write goes out and the flush after it
      # fails, the error line follows it. So the driver must require DONE to
      # be the last non-blank line, and treat an error line after it as a
      # failure.
      DONE = Egress.serialize(type: :done)

      EX_OK = 0
      # sysexits.h's EX_USAGE.
      EX_USAGE = 64

      # What exe/quaacks runs. It silences stderr, takes stdout for the CLI
      # alone, and runs argv.
      def self.main(argv, steps: STEPS)
        ErrorFilter.silence_stderr!
        new(steps:, stdin: $stdin, out: claim_stdout!).run(argv)
      end

      # Points STDOUT, file descriptor 1, at the null device for the rest of
      # the process, and returns a copy of the real stdout, which only the
      # CLI writes to. Ruby opens the copy close-on-exec, so child processes
      # don't get it either. Every write to it is flushed at once, by the CLI
      # and by ErrorFilter.guard, so it needn't be sync.
      def self.claim_stdout!
        out = STDOUT.dup # rubocop:disable Style/GlobalStdStream
        STDOUT.reopen(File::NULL, "w") # rubocop:disable Style/GlobalStdStream
        # In case something before main pointed $stdout elsewhere.
        $stdout = STDOUT
        out
      end

      # steps and store_base are there for tests. A nil store_base means
      # Store.default_base, looked up only when a step needs a run.
      def initialize(steps: STEPS, stdin: $stdin, out: $stdout, store_base: nil)
        @steps = steps
        @stdin = stdin
        @out = Output.new(out)
        @store_base = store_base
      end

      # Runs argv and returns the exit status. The one ErrorFilter.guard
      # wraps everything, so any error, even in the CLI itself, goes out as
      # one error line.
      def run(argv)
        name = ALIASES.fetch(argv.first, argv.first)
        step = @steps[name]
        step_name = step ? name : CLI_STEP
        ErrorFilter.guard(step: step_name, out: @out) { run_step(step, step_name, argv.drop(1)) }
      end

      private

      def run_step(step, step_name, args)
        raise Refused, "usage" unless step

        arguments = Arguments.parse(step, args)
        input = Input.read(@stdin) if step.input
        with_new_run(step) { |new_store| write(dispatch(step, arguments, input, new_store)) }
        EX_OK
      rescue Refused => e
        write("#{ErrorFilter.to_egress(e, step: step_name)}\n")
        EX_USAGE
      end

      # Yields a new run's Store for a step that starts one, and nil for any
      # other. If anything goes wrong before the block finishes, even a
      # signal or a failed write of the output, it deletes the run and
      # raises again. A failure to delete it doesn't hide the error that
      # caused it.
      def with_new_run(step)
        return yield(nil) unless step.new_run

        store = BadStoreBase.from_store { Store.create(base: store_base) }
        begin
          yield store
        rescue Exception # rubocop:disable Lint/RescueException
          delete_run(store)
          raise
        end
      end

      def delete_run(store)
        store.teardown
      rescue Store::Error
        nil
      end

      # Runs step and returns its output, every line of it. new_store is the
      # run with_new_run started, if any.
      def dispatch(step, arguments, input, new_store)
        store = step.run ? open_store(arguments.run_id) : new_store
        messages = call_step(step, input:, store:, options: arguments.options, **named_run(step, arguments.run_id))
        raise TypeError, "a step must return an Array of messages" unless messages.instance_of?(Array)

        [*messages.filter_map { Egress.serialize(it) }, DONE].map { "#{it}\n" }.join
      end

      # A step ends by returning. ErrorFilter.guard lets SystemExit through,
      # so an exit or abort in a step, or in a library it calls, would end
      # the process with a status of its own and no error line, or look like
      # success. So it's an internal error here. exit! can't be caught: it
      # skips every rescue and ensure, and ends the process with nothing on
      # stdout, not even DONE, so the driver must treat a run without DONE as
      # failed.
      def call_step(step, **)
        step.handler.call(**)
      rescue SystemExit
        raise StepExited, "a step called exit", cause: nil
      end

      # The run ID's form is checked first, so a missing (nil) or malformed
      # one is usage, and a well-formed one with no usable run is bad_run.
      # A store base it can't use is bad_store_base.
      def open_store(run_id)
        raise Refused, "usage" unless Store::RUN_ID.match?(run_id)

        begin
          BadStoreBase.from_store { Store.open(run_id, base: store_base) }
        rescue Store::Error
          raise Refused, "bad_run", cause: nil
        end
      end

      # What a step that names a run without opening it gets: the run ID,
      # checked as open_store checks it, and the store base. Other steps get
      # neither.
      def named_run(step, run_id)
        return {} unless step.run_id
        raise Refused, "usage" unless Store::RUN_ID.match?(run_id)

        { run_id:, store_base: }
      end

      def store_base = @store_base || Store.default_base

      def write(text)
        @out.write(text)
        @out.flush
      end
    end
  end
end
