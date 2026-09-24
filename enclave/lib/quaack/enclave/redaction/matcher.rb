# frozen_string_literal: true

require_relative "literal"

module Quaack
  module Enclave
    module Redaction
      # Matches a literal Postgres printed in a plan to the placeholders
      # whose values it could be, after its cast is set aside (the Decided
      # line of 20260922-23). A literal is [kind, text]: kind is :string, a
      # quoted literal, :number, or :boolean.
      #
      # A string matches a placeholder with exactly its text. It also
      # matches a number-typed placeholder (integer, bigint, or numeric) of
      # the same value, since Postgres prints some numbers quoted, such as
      # '-5'::integer. A number matches a placeholder of the same value,
      # whether the query wrote it as a number or as a string, as in
      # total = '5'. But a string never matches a string by number, so
      # '05' isn't '5'. A boolean matches a boolean placeholder, or a
      # string one Postgres would read as that boolean. Postgres prints a
      # bit string as a string of its bits, such as '00011111'::"bit" for
      # X'1F', so a string of 0s and 1s matches a bit string placeholder
      # with those bits.
      #
      # Text longer than MAX_NUMBER characters, or with an exponent past
      # MAX_EXPONENT, is never read as a number, so it matches only as a
      # string. Reading 1e99999999 as a Rational would take minutes.
      #
      # Postgres prints a date, time, or timestamp in its own format, such
      # as '2026-01-01 00:00:00+00' for the query's '2026-01-01', so those
      # often match nothing and are masked.
      class Matcher
        NUMBER_TYPES = %w[integer bigint numeric].freeze
        TYPES = [*NUMBER_TYPES, "boolean", "bit varying", "unknown"].freeze
        # The placeholder types a number or a boolean in a plan can match.
        NUMBERS_FROM = ["unknown", *NUMBER_TYPES].freeze
        BOOLEANS_FROM = %w[boolean unknown].freeze
        DECIMAL = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE]([+-]?\d+))?\z/
        MAX_NUMBER = 100
        MAX_EXPONENT = 1_000
        TRUE_TEXT = %w[t tr tru true y ye yes on 1].freeze
        FALSE_TEXT = %w[f fa fal fals false n no of off 0].freeze

        # map is a placeholder map, as RedactedQuery#placeholder_map gives it
        # and the governed store gives it back. Anything else raises
        # Error bad_placeholder_map. Each placeholder's value is read once,
        # here, into lookups by text, by number, by bits, and by boolean,
        # so matching a literal costs the same however many placeholders
        # there are, as for an IN list of thousands.
        def initialize(map)
          @texts = lookup
          @numbers = lookup
          @numbers_from = lookup
          @bits = lookup
          @booleans = lookup
          Redaction.checked_map(map).each { |key, entry| index(Integer(key[1..]), entry["value"], entry["type"]) }
        end

        # The numbers of the placeholders the literal could be, lowest first.
        def candidates(literal)
          kind, text = literal
          case kind
          when :string then [@texts[text], @numbers[number(text)], @bits[text]].flatten.uniq.sort
          when :number then @numbers_from[number(text)].sort
          else @booleans[text].sort
          end
        end

        private

        def lookup = Hash.new { [] }

        def index(number, value, type)
          return if value.nil?

          add(@texts, value, number)
          add(@numbers, number(value), number) if NUMBER_TYPES.include?(type)
          add(@numbers_from, number(value), number) if NUMBERS_FROM.include?(type)
          add(@bits, Literal.bits(value), number) if type == "bit varying"
          add(@booleans, boolean(value), number) if BOOLEANS_FROM.include?(type)
        end

        def add(lookup, key, number)
          lookup[key] += [number] unless key.nil?
        end

        # A number, as a Rational so that 5 and 5.0 are the same key, or nil.
        def number(text)
          return nil if text.length > MAX_NUMBER

          text = text.strip.delete("_")
          found = Literal.integer(text) || decimal(text)
          Rational(found) if found
        end

        def decimal(text)
          exponent = DECIMAL.match(text)&.[](1)
          Rational(text) if DECIMAL.match?(text) && exponent.to_i.abs <= MAX_EXPONENT
        end

        def boolean(text)
          word = text.strip.downcase
          return "true" if TRUE_TEXT.include?(word)

          "false" if FALSE_TEXT.include?(word)
        end
      end

      private_constant :Matcher
    end
  end
end
