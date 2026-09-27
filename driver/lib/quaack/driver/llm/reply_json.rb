# frozen_string_literal: true

require "json"
require_relative "error"
require_relative "reply_shape"

module Quaack
  module Driver
    module LLM
      # The client's tolerant JSON parse of a reply's text, on its own so
      # other code (the pipeline replay) reads replies the same way.
      #
      #   ReplyJSON.parse("Sure: {\"a\": []}", schema)   # => { "a" => [] }
      module ReplyJSON
        # The message leaves the reply out, and so does the parser's, which
        # quotes it. Replies carry only shapes, but a message has no need
        # for one.
        # Some models wrap the JSON in a code fence or add prose around it,
        # which may hold a stray example object too. So this falls back to
        # the objects embedded in the text: from each { in turn, the longest
        # span to a } that parses. With a schema, it takes the first object
        # that matches it, and refuses the reply if none does.
        def self.parse(text, schema)
          whole = JSON.parse(text)
          matches?(whole, schema) ? whole : raise(mismatch)
        rescue JSON::ParserError
          found = embedded_objects(text)
          raise Error.new("llm_bad_response", "the reply wasn't valid JSON"), cause: nil if found.empty?

          found.find { matches?(it, schema) } or raise mismatch, cause: nil
        end

        def self.mismatch = Error.new("llm_bad_response", "the reply didn't match the schema")

        def self.matches?(value, schema) = ReplyShape.matches?(value, schema)

        def self.embedded_objects(text)
          ends = (0...text.size).select { text[it] == "}" }.reverse
          (0...text.size).select { text[it] == "{" }.filter_map do |start|
            longest_object(text, start, ends)
          end
        end

        def self.longest_object(text, start, ends)
          ends.each do |stop|
            break if stop < start

            parsed = JSON.parse(text[start..stop])
            return parsed if parsed.is_a?(Hash)
          rescue JSON::ParserError
            next
          end
          nil
        end
      end
    end
  end
end
