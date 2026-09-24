# frozen_string_literal: true

module Quaack
  module Enclave
    class CLI
      # Wraps the CLI's stdout so each line starts on a line of its own. If
      # a write didn't finish, as when it raised partway, the next write
      # starts with a newline, so an error line written after it isn't glued
      # to a half line. The driver skips blank lines, since a write that
      # finished just as it raised leaves one.
      class Output
        def initialize(io)
          @io = io
          @at_line_start = true
        end

        def write(text)
          return 0 if text.empty?

          text ="\n#{text}" unless @at_line_start
          @at_line_start = false
          @io.write(text)
          @at_line_start = text.end_with?("\n")
          text.bytesize
        end

        def flush
          @io.flush
          self
        end
      end
    end
  end
end
