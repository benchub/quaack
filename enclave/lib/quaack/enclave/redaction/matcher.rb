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
        MATCHES = { string: :string?, number: :number?, boolean: :boolean? }.freeze
        DECIMAL = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE]([+-]?\d+))?\z/
        MAX_NUMBER = 100
        MAX_EXPONENT = 1_000
        TRUE_TEXT = %w[t tr tru true y ye yes on 1].freeze
        FALSE_TEXT = %w[f fa fal fals false n no of off 0].freeze

        # map is a placeholder map, as RedactedQuery#placeholder_map gives it
        # and the governed store gives it back. Anything else raises
        # Error bad_placeholder_map.
        def initialize(map)
          @entries = Redaction.checked_map(map).map do |key, entry|
            [Integer(key[1..]), entry["value"], entry["type"]]
          end.sort.freeze
        end

        # The numbers of the placeholders the literal could be, lowest first.
        def candidates(literal)
          kind, text = literal
          @entries.filter_map { |number, value, type| number if !value.nil? && match?(kind, text, value, type) }
        end

        private

        def match?(kind, text, value, type) = send(MATCHES.fetch(kind), text, value, type)

        def string?(text, value, type)
          text == value || (NUMBER_TYPES.include?(type) && same_number?(text, value)) ||
            (type == "bit varying" && Literal.bits(value) == text)
        end

        def number?(text, value, type) = NUMBERS_FROM.include?(type) && same_number?(text, value)

        def boolean?(text, value, type) = BOOLEANS_FROM.include?(type) && boolean(value) == text

        def same_number?(one, other)
          one = number(one)
          !one.nil? && one == number(other)
        end

        def number(text)
          text = text.strip.delete("_")
          return nil if text.length > MAX_NUMBER

          Literal.integer(text) || decimal(text)
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
