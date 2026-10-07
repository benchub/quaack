# frozen_string_literal: true

require "delegate"

module Quaack
  module Driver
    # Wraps a stream that the quaack command writes to, stderr for progress
    # and messages or stdout for what it prints, so losing it doesn't stop
    # the command. The first write that finds the stream gone, a pipe whose
    # reader has closed (`quaack run ... 2>&1 | head`, EPIPE), a connection
    # reset (ECONNRESET), or a closed stream (IOError), ends the stream:
    # that write and every later one are skipped quietly, and the command
    # goes on to its own result and exit status. Any other failure, such as
    # a full disk (ENOSPC) under a stdout sent to a file, still raises.
    # Every IO write method is guarded, and flush: print, puts, write,
    # printf, putc, and <<. Anything else, such as tty? or winsize, goes to
    # the stream.
    #
    #   stderr = QuietStream.wrap($stderr)
    #   stderr.print("quaack: ...\n")   # nil, as IO#print, written or not
    class QuietStream < SimpleDelegator
      GONE = [Errno::EPIPE, Errno::ECONNRESET, IOError].freeze

      # io as a QuietStream, unless it already is one.
      def self.wrap(io) = io.is_a?(self) ? io : new(io)

      # Makes io write through at once. $stdout otherwise holds what it's
      # given until a flush, and Ruby flushes it before it starts a child
      # process, such as ssh, so bytes held for a closed reader would raise
      # there, where no guard here can catch them.
      def initialize(io)
        super
        io.sync = true if io.respond_to?(:sync=)
      rescue IOError
        @gone = true
      end

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

      # The stream, as IO#flush answers, or nil once it's gone.
      def flush
        quietly { super } && self
      end

      private

      def quietly
        return if @gone

        yield
      rescue *GONE
        @gone = true
        nil
      end
    end
  end
end
