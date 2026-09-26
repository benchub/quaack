# frozen_string_literal: true

module Quaack
  module Enclave
    # Runs one of the operator's one-line shell commands from the quaacks
    # config, such as memory_command or run_server_command, with /bin/sh in
    # its own process group, so a timeout stops everything it started, not
    # just the shell. It gets no stdin, and its stderr is thrown away.
    #
    # A failure raises error with a rule named for prefix: <prefix>_failed
    # for a command that couldn't start or exited with a failure,
    # <prefix>_timed_out for one past its timeout, and <prefix>_bad_output
    # for one that printed more than max_output bytes. Its output is the
    # operator's and could hold anything, so it's never in an error.
    module ShellCommand
      module_function

      # The command's stdout, once it has exited with success.
      def output(command, timeout:, max_output:, error:, prefix:)
        Run.new(timeout, max_output, error, prefix).output(command)
      end

      # One run of one command.
      class Run
        def initialize(timeout, max_output, error, prefix)
          @deadline = now + timeout
          @max_output = max_output
          @error = error
          @prefix = prefix
        end

        def output(command)
          IO.pipe do |reader, writer|
            pid = spawn(command, writer)
            text = read(reader)
            fail!("failed") unless wait(pid).success?
            text
          ensure
            stop(pid)
          end
        end

        private

        def fail!(what) = raise(@error, "#{@prefix}_#{what}", cause: nil)

        def spawn(command, writer)
          Process.spawn("/bin/sh", "-c", command, in: File::NULL, out: writer, err: File::NULL, pgroup: true)
        rescue SystemCallError
          fail!("failed")
        ensure
          writer.close
        end

        # Reads until the command closes its stdout, which it may leave
        # open for a child it started.
        def read(reader)
          text = +""
          loop do
            chunk = read_some(reader)
            return text if chunk.nil?

            text << chunk
            fail!("bad_output") if text.bytesize > @max_output
          end
        end

        def read_some(reader)
          left = @deadline - now
          fail!("timed_out") unless left.positive? && reader.wait_readable(left)
          reader.read_nonblock(@max_output + 1, exception: false).then { it == :wait_readable ? +"" : it }
        end

        def wait(pid)
          loop do
            _, status = Process.wait2(pid, Process::WNOHANG)
            return status if status

            fail!("timed_out") unless now < @deadline
            sleep 0.01
          end
        end

        # Kills the command's whole process group, whatever it left
        # running, and reaps the shell if it hasn't been.
        def stop(pid)
          return unless pid

          begin
            Process.kill(:KILL, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
          reap(pid)
        end

        def reap(pid)
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
