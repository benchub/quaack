# frozen_string_literal: true

require "json"
require "strscan"
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
        # the objects embedded in the text: each { parses once, at its
        # balanced }, found by a string-aware brace-depth scan. It takes the
        # first object that matches the schema. If some object parsed but none
        # matched, the reply didn't match the schema. If none parsed, or a {
        # never closed (a reply cut off mid-object), it wasn't valid JSON.
        def self.parse(text, schema)
          whole = JSON.parse(text)
          matches?(whole, schema) ? whole : raise(mismatch)
        rescue JSON::ParserError
          embedded_match(text, schema)
        end

        def self.mismatch = Error.new("llm_bad_response", "the reply didn't match the schema")

        def self.matches?(value, schema) = ReplyShape.matches?(value, schema)

        def self.embedded_match(text, schema)
          spans, unclosed = balanced_spans(text)
          parsed = false
          spans.each do |start, stop|
            object = JSON.parse(text.byteslice(start..stop))
            parsed = true
            return object if matches?(object, schema)
          rescue JSON::ParserError
            next
          end
          raise(parsed && !unclosed ? mismatch : invalid, cause: nil)
        end

        def self.invalid = Error.new("llm_bad_response", "the reply wasn't valid JSON")

        # [[start, stop], ...] for each { with a balanced }, as byte offsets in
        # order of start, and whether any { was left open. Quotes count only
        # inside braces, since prose outside them isn't JSON. A stray { before
        # an odd quote would hide every later {, so when a scan ends with a {
        # still open, it starts again just past that {, keeping what it found.
        # Each restart rescans the rest of the text, so they stop after
        # MAX_RESTARTS, far above the few stray braces prose holds.
        OUTSIDE = /[^{]+/
        INSIDE = /(?:[^{}"]|"(?:\\.|[^"\\])*")+/m
        MAX_RESTARTS = 100

        def self.balanced_spans(text)
          spans = {}
          scanner = StringScanner.new(text)
          unclosed = false
          (MAX_RESTARTS + 1).times do
            open = scan(scanner, spans)
            unclosed ||= !open.nil?
            break unless open

            scanner.pos = open + 1
          end
          [spans.sort, unclosed]
        end

        # Scans to the end, or to a quote that never closes, and returns the
        # first { still open, if any. Each { keeps the first } it balances with.
        def self.scan(scanner, spans)
          starts = []
          while advanced?(scanner, starts, spans); end
          starts.first
        end

        # Moves past the next brace, and says whether the scan goes on.
        def self.advanced?(scanner, starts, spans)
          scanner.skip(starts.empty? ? OUTSIDE : INSIDE)
          case scanner.getch
          when "{" then starts.push(scanner.pos - 1)
          when "}" then spans[starts.pop] ||= scanner.pos - 1
          else return false
          end
          true
        end
      end
    end
  end
end
