# frozen_string_literal: true

require "delegate"

module Quaack
  module Driver
    # Wraps a stream that `quaack run` or `quaack setup` writes to, stderr
    # for progress and messages or stdout for the report's path and done,
    # so losing it doesn't stop the command. The first write that fails,
    # such as to a pipe whose reader has closed (`quaack run ... 2>&1 |
    # head`), ends the stream: that write and every later one are skipped
    # quietly, and the command goes on to its own result and exit status.
    # Every IO write method is guarded: print, puts, write, printf, putc,
    # and <<. Anything else, such as tty? or winsize, goes to the stream.
    #
    #   stderr = QuietStream.wrap($stderr)
    #   stderr.print("quaack: ...\n")   # nil, as IO#print, written or not
    class QuietStream < SimpleDelegator
      # io as a QuietStream, unless it already is one.
      def self.wrap(io) = io.is_a?(self) ? io : new(io)

      # Each of IO's write methods answers nil once skipped, but << answers
      # the stream either way, so a chain of them goes on.
      def print(*) = quietly { super }
      def puts(*) = quietly { super }
      def write(*) = quietly { super }
      def printf(*) = quietly { super }
      def putc(*) = quietly { super }

      def <<(*)
        quietly { super }
        self
      end

      private

      def quietly
        return if @gone

        yield
      rescue IOError, SystemCallError
        @gone = true
        nil
      end
    end
  end
end
