# frozen_string_literal: true

require "json"
require_relative "refused"
require_relative "../plain_data"

module Quaack
  module Enclave
    class CLI
      # Reads a step's input: one JSON object on stdin, from the driver
      # (see 20260922-5). It came from the laptop or an LLM, so it's
      # untrusted. This only parses it; the steps check what's in it.
      module Input
        # Well past any query, plan, or batch of candidates a step takes.
        MAX_BYTES = 64 * 1024 * 1024

        module_function

        # The parsed object, with String keys. It raises Refused with
        # input_too_large for more than MAX_BYTES, and with bad_input for
        # anything that isn't one JSON object in UTF-8 nested at most
        # PlainData::MAX_DEPTH deep. The parser's error can quote the input,
        # so it's left behind.
        def read(io)
          text = io.read(MAX_BYTES + 1) || +""
          raise Refused, "input_too_large" if text.bytesize > MAX_BYTES

          parse(text.force_encoding(Encoding::UTF_8))
        end

        def parse(text)
          # JSON accepts bytes that aren't UTF-8 inside a string.
          raise Refused, "bad_input" unless text.valid_encoding?

          object = begin
            # JSON doesn't count an empty innermost Array or Hash toward
            # max_nesting, so PlainData checks the depth exactly.
            PlainData.check(JSON.parse(text, max_nesting: PlainData::MAX_DEPTH))
          rescue JSON::ParserError, PlainData::NotPlain
            raise Refused, "bad_input", cause: nil
          end
          raise Refused, "bad_input" unless object.instance_of?(Hash)

          object
        end
      end
    end
  end
end
