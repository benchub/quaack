# frozen_string_literal: true

require "json"
require "strscan"
require_relative "refused"
require_relative "../plain_data"

module Quaack
  module Enclave
    class CLI
      # Reads a step's input: one JSON object on stdin, from the driver
      # (see 20260922-5). It came from the laptop or an LLM, so it's
      # untrusted. This only parses it; the steps check what's in it.
      #
      # It must mean the same thing whichever json is loaded. The jump
      # server runs outside Bundler, so it gets Ruby 3.4's default json
      # (2.9.1), which takes the last of a repeated key, skips /* */ and //
      # comments, and keeps the character after an unknown escape such as
      # \q. The bundle's json (3.0.2) refuses all three. So Input refuses
      # them itself, on every version: a repeated key is ambiguous, and the
      # driver writes its input with JSON.generate, which never writes a
      # comment or an unknown escape. Both versions read a number too big
      # for a Float as Infinity, which Input refuses too.
      module Input
        # Well past any query, plan, or batch of candidates a step takes.
        MAX_BYTES = 64 * 1024 * 1024

        # Parsing into this finds a key repeated in one object, on any json
        # version: the parser sets each key with []=.
        class UniqueKeys < Hash
          class Repeated < StandardError; end

          def []=(key, value)
            raise Repeated, "a key is repeated" if key?(key)

            super
          end
        end

        # What the lexical scan looks for. None of these repeats, since a
        # regex that repeats over each character can keep a backtrack entry
        # per character, even with a possessive quantifier: about 70 bytes a
        # character, or 5 GB for MAX_BYTES. Searching with skip_until for a
        # single character keeps none.
        #
        # Outside a string, JSON never has a slash, so one there starts a
        # comment. Inside one, a backslash starts an escape.
        OUTSIDE = %r{["/]}
        INSIDE = /["\\]/
        # The characters JSON allows after a backslash.
        ESCAPES = %w[" \\ / b f n r t u].freeze

        module_function

        # The parsed object, with String keys. It raises Refused with
        # input_too_large for more than MAX_BYTES, and with bad_input for
        # anything that isn't one JSON object in UTF-8 nested at most
        # PlainData::MAX_DEPTH deep, with no key repeated in an object, no
        # comments, no unknown escapes, and no Float that isn't finite. The
        # parser's error can quote the input, so it's left behind.
        def read(io)
          text = io.read(MAX_BYTES + 1) || +""
          raise Refused, "input_too_large" if text.bytesize > MAX_BYTES

          parse(text.force_encoding(Encoding::UTF_8))
        end

        def parse(text)
          object = parse_document(text)
          raise Refused, "bad_input" unless object.instance_of?(Hash)

          object
        end

        # Like parse, but for any one JSON document, not only an object.
        # Intake reads the operator's plan file with it, since EXPLAIN's
        # JSON is an Array.
        def parse_document(text)
          # JSON accepts bytes that aren't UTF-8 inside a string.
          raise Refused, "bad_input" unless text.valid_encoding? && !lexical_problem?(text)

          object = begin
            # The first parse only looks for a repeated key. The second
            # gives plain Hashes. JSON doesn't count an empty innermost
            # Array or Hash toward max_nesting, so PlainData checks the
            # depth exactly.
            JSON.parse(text, max_nesting: PlainData::MAX_DEPTH, object_class: UniqueKeys)
            PlainData.check(JSON.parse(text, max_nesting: PlainData::MAX_DEPTH))
          rescue JSON::ParserError, UniqueKeys::Repeated, PlainData::NotPlain
            raise Refused, "bad_input", cause: nil
          end
          raise Refused, "bad_input" unless finite?(object)

          object
        end

        # Whether text has a comment, or an unknown escape in a string, in
        # time and memory linear in its size. It stops at a string that never
        # closes, which JSON refuses anyway.
        def lexical_problem?(text)
          scanner = StringScanner.new(text)
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

            # At the end of the text, getch gives nil, which isn't in
            # ESCAPES either, and JSON would refuse it anyway.
            return true unless ESCAPES.include?(scanner.getch)
          end
          false
        end

        # Whether every Float in object is finite. It walks with its own
        # stack, since PlainData has already capped the depth but recursion
        # that deep could still run out of stack.
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
