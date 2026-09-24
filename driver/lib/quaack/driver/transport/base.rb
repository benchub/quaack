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
        # The most the enclave script's argv may hold, counting each
        # argument's bytes and its NUL. Well under any system's limit on
        # argv, since larger input belongs on stdin.
        MAX_ARGV_BYTES = 64 * 1024

        # timeout is in seconds. Each must be a positive number.
        def initialize(timeout: DEFAULT_TIMEOUT, max_output_bytes: MAX_OUTPUT_BYTES)
          @timeout = positive(timeout, "timeout")
          @max_output_bytes = positive(max_output_bytes, "max_output_bytes")
        end

        # Runs `quaacks <subcommand>` with args as its options and input as
        # its stdin, and returns a Result. It raises EnclaveError if the run
        # failed, including with rule not_started if the command couldn't
        # be run at all, and ArgumentError, before running anything, for a
        # subcommand, args, or input the enclave's CLI can't take. Neither
        # ever carries a cause, even when call runs inside a rescue.
        #
        # Each arg becomes `--name value`, or `--name` alone for a value of
        # true, a flag, in the order given. Names may be Strings or Symbols.
        # Values must be Strings of valid UTF-8, with no NUL, and all of
        # argv at most MAX_ARGV_BYTES. input is a Hash, sent as one JSON
        # document written by JSON.generate, or nil to send nothing.
        def call(subcommand, args: {}, input: nil)
          argv = argv(subcommand, args)
          run = run(argv, stdin(input))
          raise Reply.failure(argv.first, run.status, rule: run.limit.name), cause: nil if run.limit

          Result.new(messages: Reply.parse(run.stdout, run.status, subcommand: argv.first))
        end

        private

        def run(argv, stdin)
          Child.run(command(argv), stdin:, timeout: @timeout, max_output_bytes: @max_output_bytes)
        rescue Child::NotStarted
          raise EnclaveError.new(subcommand: argv.first, rule: "not_started"), cause: nil
        end

        # Raises ArgumentError with no cause.
        def refuse(message) = raise(ArgumentError, message, cause: nil)

        def positive(value, what)
          return value if value.is_a?(Numeric) && value.positive?

          refuse("#{what} must be a positive number")
        end

        # Whether value is a String of valid UTF-8 with no NUL, in an
        # encoding that reads as UTF-8, such as UTF-8, US-ASCII, or binary
        # holding only UTF-8.
        def text?(value)
          value.is_a?(String) && value.encoding.ascii_compatible? &&
            value.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !value.include?("\0")
        end

        # A non-empty Array of non-empty text, such as a command.
        def words?(value) = value.is_a?(Array) && !value.empty? && value.all? { text?(it) && !it.empty? }

        def argv(subcommand, args)
          refuse("args must be a Hash") unless args.is_a?(Hash)

          argv = [name(subcommand, "subcommand"), *args.flat_map { |key, value| option(key, value) }]
          refuse("argv holds more than #{MAX_ARGV_BYTES} bytes") if argv.sum { it.bytesize + 1 } > MAX_ARGV_BYTES
          argv
        end

        # The enclave's CLI reads one JSON object, so input must be a Hash.
        def stdin(input)
          return if input.nil?

          refuse("input must be a Hash") unless input.is_a?(Hash)

          JSON.generate(input)
        rescue JSON::GeneratorError, JSON::NestingError
          refuse("input can't be written as JSON")
        end

        def name(value, what)
          value = value.name if value.is_a?(Symbol)
          return value if text?(value) && NAME.match?(value)

          refuse("not a #{what} quaacks takes: #{value.inspect}")
        end

        def option(key, value)
          option = "--#{name(key, "option name")}"
          return [option] if value == true

          refuse("#{option} needs a String value of valid UTF-8 with no NUL") unless text?(value)

          [option, value]
        end
      end
    end
  end
end
