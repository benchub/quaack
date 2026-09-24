# frozen_string_literal: true

require "strscan"

module Quaack
  module Driver
    module Transport
      # The checks Reply makes on a line of JSON beyond what the parser does,
      # so the line reads the same way on every json version (see Reply).
      module Lexical
        # What problem? looks for, outside a string and inside one.
        OUTSIDE = %r{["/]}
        INSIDE = /["\\]/
        # The characters JSON allows after a backslash.
        ESCAPES = %w[" \\ / b f n r t u].freeze

        module_function

        # Whether line holds a comment, or an unknown escape in a string.
        # Outside a string, JSON never has a slash, so one there starts a
        # comment. Inside one, a backslash starts an escape. It skips ahead
        # to each with skip_until, so it takes time and memory linear in the
        # line. A line cut off inside a string or an escape has neither.
        def problem?(line)
          scanner = StringScanner.new(line)
          while scanner.skip_until(OUTSIDE)
            return true if scanner.matched == "/"
            return true if bad_string?(scanner)
          end
          false
        end

        # Scans the rest of a string, after its opening quote, through its
        # closing quote, and says whether it has an unknown escape.
        def bad_string?(scanner)
          while scanner.skip_until(INSIDE)
            return false if scanner.matched == '"'

            escape = scanner.getch
            return true unless escape.nil? || ESCAPES.include?(escape)
          end
          false
        end

        # Whether every Float in object is finite. It walks with its own
        # stack, since the object can nest Reply::MAX_NESTING deep.
        def finite?(object)
          stack = [object]
          until stack.empty?
            item = stack.pop
            case item
            when Hash then stack.concat(item.values)
            when Array then stack.concat(item)
            when Float then return false unless item.finite?
            end
          end
          true
        end
      end
    end
  end
end
