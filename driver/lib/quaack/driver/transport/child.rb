# frozen_string_literal: true

require "open3"

module Quaack
  module Driver
    module Transport
      # Runs one command in a child process, with no shell: writes stdin to
      # it, reads its stdout, and waits for it to end. Its stderr goes to the
      # null device. The enclave script silences its own, so only ssh's own
      # messages would land there, and the driver reports a failed run by
      # what's on stdout and how it ended.
      #
      # It writes stdin and reads stdout in one loop, without blocking on
      # either, so a child that fills its stdout before reading all of stdin
      # can't deadlock with it, and there's no writer thread to outlive the
      # call. A child that ends without reading all of stdin is its own
      # business: once the child has ended, stdin is closed, even if
      # something the child started still holds it open.
      #
      # A child that runs past its deadline, or prints more than the cap, is
      # killed: SIGTERM, then SIGKILL if it's still running GRACE seconds
      # later. The child runs in its own process group, and the signals go
      # to the whole group, so whatever a shell child started dies with it.
      # So is one still running when the driver itself stops, as on
      # a Ctrl-C.
      module Child
        # What run gives back. limit is nil, or :timeout or
        # :output_too_large if the child was killed for going past one.
        Run = Data.define(:stdout, :status, :limit)

        # The command couldn't be started, as when it doesn't exist.
        class NotStarted < StandardError; end

        GRACE = 2
        CHUNK = 64 * 1024

        module_function

        # argv is the command and its arguments, and stdin is a String or
        # nil. timeout is in seconds.
        def run(argv, stdin:, timeout:, max_output_bytes:)
          deadline = now + timeout
          # The [command, argv0] form never goes through a shell, even when
          # argv has only one element.
          input, output, waiter = start(argv)
          stdout, limit = Pump.new(input, output, stdin, deadline:, max_bytes: max_output_bytes).run
          limit ||= wait(waiter, deadline)
          terminate(waiter) if limit
          Run.new(stdout:, status: waiter.value, limit:)
        ensure
          clean_up(waiter, input, output)
        end

        def start(argv)
          Open3.popen2([argv.first, argv.first], *argv.drop(1), err: File::NULL, pgroup: true)
        rescue SystemCallError
          raise NotStarted, "the command couldn't be started", cause: nil
        end

        # nil once the child has ended, or :timeout if it's still running at
        # the deadline. Its stdout can close before it ends.
        def wait(waiter, deadline) = (:timeout unless waiter.join([deadline - now, 0].max))

        # Kills the child if it's still running, as when the driver itself
        # was interrupted, and closes what run opened.
        def clean_up(waiter, input, output)
          terminate(waiter) if waiter&.alive?
          input&.close
          output&.close
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def terminate(waiter)
          signal(waiter.pid, "TERM")
          return if waiter.join(GRACE)

          signal(waiter.pid, "KILL")
          waiter.join
        end

        def signal(pid, name)
          Process.kill(name, -pid)
        rescue Errno::ESRCH
          nil
        end

        # Writes stdin to input and reads output until output closes, the
        # deadline passes, or output holds more than max_bytes. run returns
        # [stdout as read, limit], where limit is :output_too_large or nil.
        # At the deadline it just stops: Child.wait then finds the child
        # still running and calls it a timeout.
        class Pump
          def initialize(input, output, stdin, deadline:, max_bytes:)
            @input = input
            @output = output
            # An empty stdin is written as zero bytes, which closes input.
            @pending = (stdin || "").b
            @deadline = deadline
            @max_bytes = max_bytes
            @stdout = +""
          end

          def run
            loop do
              readable, writable = IO.select([@output], writing? ? [@input] : [], nil, remaining)
              return [@stdout, nil] if readable.nil?

              write if writable.any?
              next if readable.empty?

              limit = read
              return [@stdout, limit == :eof ? nil : limit] if limit
            end
          end

          private

          def remaining = [@deadline - Child.now, 0].max
          def writing? = !@input.closed?

          # Writes what it can of the rest of stdin, and closes input once
          # it's all written, or once the child has closed its end.
          def write
            written = @input.write_nonblock(@pending, exception: false)
            return if written == :wait_writable

            @pending = @pending.byteslice(written..)
            finish_writing if @pending.empty?
          rescue IOError, SystemCallError
            finish_writing
          end

          def finish_writing = @input.close

          # nil to keep going, :eof once output closes, or :output_too_large.
          def read
            chunk = @output.read_nonblock(CHUNK, exception: false)
            return :eof if chunk.nil?
            return if chunk == :wait_readable

            @stdout << chunk
            :output_too_large if @stdout.bytesize > @max_bytes
          end
        end
      end
    end
  end
end
