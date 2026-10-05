# frozen_string_literal: true

module Quaack
  module Driver
    # Checks on the driver's arguments before any subcommand reads them.
    module Arguments
      SUBCOMMANDS = %w[start setup run deploy].freeze

      # Prints the usage error for the first argument that isn't valid
      # UTF-8 and returns its exit status, 64, or returns nil if every
      # argument is. It names the subcommand, and the flag the argument is
      # the value of, if usage shows it with one, as in `--run <ID>`, but
      # never the argument, since the arguments go on to ssh, regexes, and
      # file names.
      def self.not_utf8(argv, usage, stderr)
        i = argv.index { !it.dup.force_encoding(Encoding::UTF_8).valid_encoding? } or return
        command = SUBCOMMANDS.include?(argv.first) ? "quaack #{argv.first}" : "quaack"
        flag = argv[i - 1] if i > 1 && usage.scan(/--[a-z-]+(?= <)/).include?(argv[i - 1])
        stderr.print("#{command}: #{flag || "an argument"} isn't valid UTF-8\n") || 64
      end
    end
  end
end
