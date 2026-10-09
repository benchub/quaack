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
          spans = Spans.new(text)
          parsed = false
          spans.each do |object|
            parsed = true
            return object if matches?(object, schema)
          end
          raise(parsed && !spans.unclosed ? mismatch : invalid, cause: nil)
        end

        def self.invalid = Error.new("llm_bad_response", "the reply wasn't valid JSON")

        # Spans map each { with a balanced } to that }, as byte offsets.
        # Quotes count only inside braces, since prose outside them isn't JSON. A stray { before
        # an odd quote would hide every later {, so when a scan ends with a {
        # still open, it starts again just past that {, keeping what it found.
        # Stray quotes that pair up can instead swallow the real object into a
        # stray {'s span, so when a span doesn't parse, it rescans that span's
        # interior too. Each restart rescans the rest of the text, so
        # they stop after MAX_RESTARTS, far above the few stray braces prose holds.
        OUTSIDE = /[^{]+/
        INSIDE = /(?:[^{}"]|"(?:\\.|[^"\\])*")+/m
        MAX_RESTARTS = 100

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

        # The objects embedded in a text, parsed in order of their {, with the
        # restarts above. unclosed says whether the first scan left a { open.
        class Spans
          attr_reader :unclosed

          def initialize(text)
            @text = text
            @spans = {}
            @restarts = MAX_RESTARTS + 1
            @unclosed = collect(StringScanner.new(text), 0, @spans)
          end

          def each
            queue = @spans.sort
            until queue.empty?
              start, stop = queue.shift
              if (result = parsed(start, stop))
                yield result.first
              elsif (found = rescan(start, stop)).any?
                queue = (queue + found).sort
              end
            end
          end

          private

          # [object], or nil when the span isn't JSON.
          def parsed(start, stop)
            [JSON.parse(@text.byteslice(start..stop))]
          rescue JSON::ParserError
            nil
          end

          # Only quotes can hide braces, so a failed span's interior gets a
          # fresh scan only when it holds one. Spans past its } are already
          # known, so the scan stays inside. Returns the new spans.
          def rescan(start, stop)
            interior = @text.byteslice((start + 1)...stop)
            return [] unless interior.include?('"')

            found = {}
            collect(StringScanner.new(interior), 0, found)
            added(found, start + 1)
          end

          # Records the spans an interior scan found at offset, and returns
          # those that are new.
          def added(found, offset)
            found.map { |s, e| [s + offset, e + offset] }
                 .reject { |s, _| @spans.key?(s) }
                 .each { |s, e| @spans[s] = e }
          end

          # Scans from pos, then restarts past each { left open, while
          # restarts last. Each scan spends one. Says whether a { was left
          # open.
          def collect(scanner, pos, spans)
            unclosed = false
            while @restarts.positive?
              @restarts -= 1
              scanner.pos = pos
              pos = ReplyJSON.scan(scanner, spans)
              unclosed ||= !pos.nil?
              break unless pos

              pos += 1
            end
            unclosed
          end
        end
      end
    end
  end
end
