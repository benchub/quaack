# frozen_string_literal: true

require_relative "version"

module Quaack
  module Driver
    # The quaack command line, run by an engineer on their laptop.
    class CLI
      USAGE = "Usage: quaack --version\n       " \
              "quaack start --server <name> --query <file> --plan <file>\n"
      EX_USAGE = 64
      START_OPTIONS = %w[--server --query --plan].freeze

      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      def run(argv)
        if argv == ["--version"]
          @stdout.print "quaack #{VERSION}\n"
          0
        elsif argv.first == "start" && (options = start_options(argv.drop(1)))
          start(options)
        else
          @stderr.print USAGE
          EX_USAGE
        end
      end

      private

      # The start options as a Hash, or nil unless argv is each of them
      # exactly once, with a value.
      def start_options(argv)
        return unless argv.size == 2 * START_OPTIONS.size

        pairs = argv.each_slice(2).to_a
        return unless pairs.map(&:first).sort == START_OPTIONS.sort

        pairs.to_h { |name, value| [name.delete_prefix("--").to_sym, value] }
      end

      # Prints the run ID, or only the rule of a failure: the enclave's
      # errors already went through its egress.
      def start(options)
        require_relative "start"
        @stdout.print "#{Start.new.call(**options)}\n"
        0
      rescue Start::Error, EnclaveError => e
        @stderr.print "quaack start failed: #{e.is_a?(EnclaveError) ? e.rule : e.message}\n"
        1
      end
    end
  end
end
