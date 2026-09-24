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
      # A child that runs past its deadline, or prints more than the cap, is
      # killed: SIGTERM, then SIGKILL if it's still running GRACE seconds
      # later. So is one still running when the driver itself stops, as on
      # a Ctrl-C.
      module Child
        # What run gives back. limit is nil, or :timeout or
        # :output_too_large if the child was killed for going past one.
        Run = Data.define(:stdout, :status, :limit)

        GRACE = 2
        CHUNK = 64 * 1024

        module_function

        # argv is the command and its arguments, and stdin is a String or
        # nil. timeout is in seconds.
        def run(argv, stdin:, timeout:, max_output_bytes:)
          deadline = now + timeout
          # The [command, argv0] form never goes through a shell, even when
          # argv has only one element.
          input, output, waiter = Open3.popen2([argv.first, argv.first], *argv.drop(1), err: File::NULL)
          writer = write(input, stdin)
          stdout, limit = read(output, deadline, max_output_bytes)
          limit ||= wait(waiter, deadline)
          terminate(waiter) if limit
          Run.new(stdout:, status: waiter.value, limit:)
        ensure
          clean_up(waiter, writer, output)
        end

        # nil once the child has ended, or :timeout if it's still running at
        # the deadline. Its stdout can close before it ends.
        def wait(waiter, deadline) = (:timeout unless waiter.join([deadline - now, 0].max))

        # Kills the child if it's still running, as when the driver itself
        # was interrupted, and closes what run opened.
        def clean_up(waiter, writer, output)
          terminate(waiter) if waiter&.alive?
          writer&.join
          output&.close
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Writes stdin on a thread of its own, so a child that fills its
        # stdout before reading all of stdin can't deadlock with it, and
        # closes it. A child that ends without reading it all closes the
        # pipe, which is its business.
        def write(input, stdin)
          Thread.new do
            input.write(stdin) if stdin
          rescue IOError, SystemCallError
            nil
          ensure
            input.close
          end
        end

        # [stdout as read, limit], reading until the child closes it, the
        # deadline passes, or it holds more than max_bytes.
        def read(output, deadline, max_bytes)
          stdout = +""
          loop do
            return [stdout, :timeout] unless output.wait_readable([deadline - now, 0].max)

            chunk = output.read_nonblock(CHUNK, exception: false)
            return [stdout, nil] if chunk.nil?
            next if chunk == :wait_readable

            stdout << chunk
            return [stdout, :output_too_large] if stdout.bytesize > max_bytes
          end
        end

        def terminate(waiter)
          signal(waiter.pid, "TERM")
          return if waiter.join(GRACE)

          signal(waiter.pid, "KILL")
          waiter.join
        end

        def signal(pid, name)
          Process.kill(name, pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
