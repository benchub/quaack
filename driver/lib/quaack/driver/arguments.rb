# frozen_string_literal: true

module Quaack
  module Driver
    # Checks on the driver's arguments before any subcommand reads them.
    module Arguments
      SUBCOMMANDS = %w[start setup run deploy].freeze

      # Prints the usage error for the first argument that isn't valid
      # UTF-8 and returns its exit status, 64, or returns nil if every
      # argument is. It names the subcommand, and the flag the argument is
      # the value of, if any, but never the argument, since the arguments
      # go on to ssh, regexes, and file names. A flag takes a value if the
      # subcommand's line of usage shows it with one, as in `--run <ID>`,
      # and flags pair with values left to right.
      def self.not_utf8(argv, usage, stderr)
        i = argv.index { !it.dup.force_encoding(Encoding::UTF_8).valid_encoding? } or return
        command = SUBCOMMANDS.include?(argv.first) ? "quaack #{argv.first}" : "quaack"
        flag = value_of(argv, i, usage.lines.find { it.include?("#{command} ") }.to_s.scan(/--[a-z-]+(?= <)/))
        stderr.print("#{command}: #{flag || "an argument"} isn't valid UTF-8\n") || 64
      end

      # The flag in flags whose value argv[bad] is, or nil.
      def self.value_of(argv, bad, flags)
        j = 1
        j += flags.include?(argv[j]) ? 2 : 1 while j < bad - 1
        argv[j] if flags.include?(argv[j])
      end
      private_class_method :value_of
    end
  end
end
