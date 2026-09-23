# frozen_string_literal: true

require_relative "version"

module Quaack
  module Driver
    # The quaack command line, run by an engineer on their laptop.
    class CLI
      USAGE = "Usage: quaack --version\n"
      EX_USAGE = 64

      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      def run(argv)
        if argv == ["--version"]
          @stdout.print "quaack #{VERSION}\n"
          0
        else
          @stderr.print USAGE
          EX_USAGE
        end
      end
    end
  end
end
