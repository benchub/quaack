# frozen_string_literal: true

require "shellwords"
require_relative "error"

module Quaack
  module Enclave
    module Inventory
      # Finds the production server's instance memory (README, step 2) with
      # the operator's memory command, a one-line shell command from the
      # quaacks config (see Config), so any cloud provider's tools can do
      # it. Every {host} in it becomes the production host, as one shell
      # word, and /bin/sh runs it on the jump server, with no stdin and its
      # stderr thrown away.
      #
      # It must print the memory in bytes, as a plain whole number, or as a
      # whole number and a unit: kB, MB, GB, or TB, or KiB, MiB, GiB, or TiB,
      # in any case, with or without a space. Every unit is binary, as in
      # Postgres, so 1GB and 1GiB are both 1024**3 bytes. Blank space around
      # it, such as a trailing newline, is fine.
      #
      # A command that exits with a failure is memory_command_failed, one
      # that runs past its timeout is memory_command_timed_out, and anything
      # else it prints, or more than MAX_OUTPUT bytes, is
      # memory_command_bad_output. Its output is the operator's, and it
      # could hold anything, so it's never in an error.
      module Memory
        # Far more than any size it could print.
        MAX_OUTPUT = 256
        # Seconds. A cloud provider's command line tool can be slow to start.
        TIMEOUT = 30
        HOST = "{host}"
        SIZE = /\A\s*([1-9][0-9]*)(?: ?([kmgt])i?b)?\s*\z/i
        UNITS = { "k" => 1, "m" => 2, "g" => 3, "t" => 4 }.freeze

        module_function

        # The size text gives, in bytes.
        def parse(text)
          match = SIZE.match(text)
          raise Error, "memory_command_bad_output" unless match

          Integer(match[1], 10) * (1024**UNITS.fetch(match[2].to_s.downcase, 0))
        end

        # Runs template with host filled in, and returns the memory it gives,
        # in bytes.
        def bytes(template, host, timeout: TIMEOUT)
          parse(Command.output(template.gsub(HOST) { Shellwords.escape(host) }, timeout))
        end

        # Runs one command in its own process group, so a timeout stops
        # everything it started, not just the shell.
        module Command
          module_function

          # The command's stdout, once it has exited with success.
          def output(command, timeout)
            deadline = now + timeout
            IO.pipe do |reader, writer|
              pid = spawn(command, writer)
              run(pid, reader, deadline)
            ensure
              stop(pid)
            end
          end

          def spawn(command, writer)
            Process.spawn("/bin/sh", "-c", command, in: File::NULL, out: writer, err: File::NULL, pgroup: true)
          rescue SystemCallError
            raise Error, "memory_command_failed", cause: nil
          ensure
            writer.close
          end

          def run(pid, reader, deadline)
            text = read(reader, deadline)
            raise Error, "memory_command_failed" unless wait(pid, deadline).success?

            text
          end

          # Reads until the command closes its stdout, which it may leave
          # open for a child it started.
          def read(reader, deadline)
            text = +""
            loop do
              chunk = read_some(reader, deadline)
              return text if chunk.nil?

              text << chunk
              raise Error, "memory_command_bad_output" if text.bytesize > MAX_OUTPUT
            end
          end

          def read_some(reader, deadline)
            left = deadline - now
            timed_out! unless left.positive? && reader.wait_readable(left)
            reader.read_nonblock(MAX_OUTPUT, exception: false).then { it == :wait_readable ? +"" : it }
          end

          def wait(pid, deadline)
            loop do
              _, status = Process.wait2(pid, Process::WNOHANG)
              return status if status

              timed_out! unless now < deadline
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

          def timed_out! = raise(Error, "memory_command_timed_out")

          def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
