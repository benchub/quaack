# frozen_string_literal: true

require_relative "version"

module Quaack
  module Enclave
    # The quaack-enclave command line. The driver calls it over ssh. Stdout is
    # the channel back to the driver, so usage errors go to stderr only.
    class CLI
      USAGE = "Usage: quaack-enclave --version\n"
      EX_USAGE = 64

      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      def run(argv)
        if argv == ["--version"]
          @stdout.print "quaack-enclave #{VERSION}\n"
          0
        else
          @stderr.print USAGE
          EX_USAGE
        end
      end
    end
  end
end
