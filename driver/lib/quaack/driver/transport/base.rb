# frozen_string_literal: true

require "json"
require_relative "child"
require_relative "reply"

module Quaack
  module Driver
    module Transport
      # What a run that succeeded printed: each message as a Hash with
      # String keys, in order, without the final done line.
      Result = Data.define(:messages)

      # What every transport does with a call. A subclass says how to run
      # the enclave script, as command(argv), the command that runs
      # `quaacks *argv`.
      class Base
        # A subcommand, and an option name without its dashes, as the
        # enclave's CLI names them, such as intake and captured-at.
        NAME = /\A[a-z][a-z0-9-]{0,62}\z/

        # How long a call may run, in seconds, before the driver kills it.
        # Some steps run many queries, so it's generous. The driver's config
        # passes its own to the transport.
        DEFAULT_TIMEOUT = 3600
        # The most a call may print. Far more than any step's messages.
        MAX_OUTPUT_BYTES = 64 * 1024 * 1024

        # timeout is in seconds. Each must be a positive number.
        def initialize(timeout: DEFAULT_TIMEOUT, max_output_bytes: MAX_OUTPUT_BYTES)
          @timeout = positive(timeout, "timeout")
          @max_output_bytes = positive(max_output_bytes, "max_output_bytes")
        end

        # Runs `quaacks <subcommand>` with args as its options and input as
        # its stdin, and returns a Result. It raises EnclaveError if the run
        # failed, and ArgumentError, before running anything, for a
        # subcommand, args, or input the enclave's CLI can't take.
        #
        # Each arg becomes `--name value`, or `--name` alone for a value of
        # true, a flag, in the order given. Names may be Strings or Symbols.
        # Values must be Strings, since argv holds only text. Ruby refuses
        # to start a process with a NUL in its argv, with an ArgumentError
        # too. input is a Hash, sent as one JSON document written by
        # JSON.generate, or nil to send nothing.
        def call(subcommand, args: {}, input: nil)
          argv = argv(subcommand, args)
          stdin = stdin(input)
          run = Child.run(command(argv), stdin:, timeout: @timeout, max_output_bytes: @max_output_bytes)
          raise Reply.failure(argv.first, run.status, rule: run.limit.name) if run.limit

          Result.new(messages: Reply.parse(run.stdout, run.status, subcommand: argv.first))
        end

        private

        def positive(value, what)
          return value if value.is_a?(Numeric) && value.positive?

          raise ArgumentError, "#{what} must be a positive number"
        end

        def argv(subcommand, args)
          raise ArgumentError, "args must be a Hash" unless args.is_a?(Hash)

          [name(subcommand, "subcommand"), *args.flat_map { |key, value| option(key, value) }]
        end

        # The enclave's CLI reads one JSON object, so input must be a Hash.
        def stdin(input)
          return if input.nil?
          raise ArgumentError, "input must be a Hash" unless input.is_a?(Hash)

          JSON.generate(input)
        rescue JSON::GeneratorError, JSON::NestingError
          raise ArgumentError, "input can't be written as JSON", cause: nil
        end

        def name(value, what)
          value = value.name if value.is_a?(Symbol)
          return value if value.is_a?(String) && NAME.match?(value)

          raise ArgumentError, "not a #{what} quaacks takes: #{value.inspect}"
        end

        def option(key, value)
          option = "--#{name(key, "option name")}"
          return [option] if value == true
          raise ArgumentError, "#{option} needs a String value" unless value.is_a?(String)

          [option, value]
        end
      end
    end
  end
end
