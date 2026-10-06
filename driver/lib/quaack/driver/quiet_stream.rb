# frozen_string_literal: true

require "delegate"

module Quaack
  module Driver
    # Wraps the stream that `quaack run`'s progress and messages go to,
    # stderr, so losing it doesn't stop the run. The first write that
    # fails, such as to a pipe whose reader has closed (`quaack run ...
    # 2>&1 | head`), ends the stream: that write and every later one are
    # skipped quietly, and the run goes on to its own result and exit
    # status. Anything else, such as tty? or winsize, goes to the stream.
    #
    #   stderr = QuietStream.wrap($stderr)
    #   stderr.print("quaack: ...\n")   # nil, as IO#print, written or not
    class QuietStream < SimpleDelegator
      # io as a QuietStream, unless it already is one.
      def self.wrap(io) = io.is_a?(self) ? io : new(io)

      def print(*) = quietly { super }

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
