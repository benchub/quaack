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
      # (2.9.1), which takes the last of a repeated key and skips /* */ and
      # // comments. The bundle's json (3.0.2) refuses both. So Input
      # refuses both itself, on every version: a repeated key is ambiguous,
      # and the driver writes its input with JSON.generate, which never
      # writes a comment.
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

        # Outside a string, JSON never has a slash, so one there starts a
        # comment. A string is a quote, then anything but a quote or
        # backslash or an escape, then a quote. The quantifiers are
        # possessive, so nothing backtracks.
        STRING = /"(?:[^"\\]++|\\.)*+"/m
        NOT_STRING_OR_SLASH = %r{[^"/]++}

        module_function

        # The parsed object, with String keys. It raises Refused with
        # input_too_large for more than MAX_BYTES, and with bad_input for
        # anything that isn't one JSON object in UTF-8 nested at most
        # PlainData::MAX_DEPTH deep, with no key repeated in an object and no
        # comments. The parser's error can quote the input, so it's left
        # behind.
        def read(io)
          text = io.read(MAX_BYTES + 1) || +""
          raise Refused, "input_too_large" if text.bytesize > MAX_BYTES

          parse(text.force_encoding(Encoding::UTF_8))
        end

        def parse(text)
          # JSON accepts bytes that aren't UTF-8 inside a string.
          raise Refused, "bad_input" unless text.valid_encoding? && !comment?(text)

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
          raise Refused, "bad_input" unless object.instance_of?(Hash)

          object
        end

        # Whether text has a slash outside a string. It skips everything
        # else and every string, and stops at the end, at a slash, or at a
        # string that never closes, which JSON refuses anyway.
        def comment?(text)
          scanner = StringScanner.new(text)
          loop do
            next if scanner.skip(NOT_STRING_OR_SLASH) || scanner.skip(STRING)

            return scanner.check(%r{/}) ? true : false
          end
        end
      end
    end
  end
end
