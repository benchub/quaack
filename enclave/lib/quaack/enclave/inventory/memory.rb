# frozen_string_literal: true

require "shellwords"
require_relative "error"
require_relative "../shell_command"

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
          command = template.gsub(HOST) { Shellwords.escape(host) }
          parse(ShellCommand.output(command, timeout:, max_output: MAX_OUTPUT, error: Error, prefix: "memory_command"))
        end
      end
    end
  end
end
