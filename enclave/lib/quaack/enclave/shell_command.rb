# frozen_string_literal: true

module Quaack
  module Enclave
    # Runs one of the operator's one-line shell commands from the quaacks
    # config, such as memory_command or run_server_command, with /bin/sh in
    # its own process group, so a timeout stops everything it started, not
    # just the shell. It gets no stdin, and its stderr is thrown away. Its
    # output is what it printed by the time the shell exited, so a child
    # left in the background holding stdout doesn't keep it waiting, and
    # the child is stopped with the rest of the group. Unsupported in v1: a
    # child that leaves the group, as with setsid, isn't stopped.
    #
    # A failure raises error with a rule named for prefix: <prefix>_failed
    # for a command that couldn't start or exited with a failure,
    # <prefix>_timed_out for one past its timeout, and <prefix>_bad_output
    # for one that printed more than max_output bytes. Its output is the
    # operator's and could hold anything, so it's never in an error.
    module ShellCommand
      # Seconds to wait for output before checking whether the shell exited.
      POLL = 0.05

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
            text, status = collect(reader, pid)
            fail!("failed") unless status.success?
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

        # The command's output and exit status. It reads until the shell
        # exits, then takes what's left in the pipe. The status is checked
        # before each read, so everything the shell wrote is in the pipe by
        # the last one. If stdout closes first, it waits for the exit.
        def collect(reader, pid)
          text = +""
          loop do
            status = exited(pid)
            closed = drained_to_eof?(reader, text, status ? 0 : [POLL, @deadline - now].min)
            return [text, status] if status
            return [text, wait(pid)] if closed

            fail!("timed_out") unless now < @deadline
          end
        end

        # Adds what reader has to text, waiting up to wait seconds for the
        # first of it. Whether stdout has closed.
        def drained_to_eof?(reader, text, wait)
          while reader.wait_readable([wait, 0].max)
            chunk = reader.read_nonblock(@max_output + 1, exception: false)
            return true if chunk.nil?

            text << chunk unless chunk == :wait_readable
            fail!("bad_output") if text.bytesize > @max_output
            wait = 0
          end
          false
        end

        def exited(pid) = Process.wait2(pid, Process::WNOHANG)&.last

        def wait(pid)
          loop do
            status = exited(pid)
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
