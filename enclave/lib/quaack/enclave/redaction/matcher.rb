# frozen_string_literal: true

require_relative "literal"

module Quaack
  module Enclave
    module Redaction
      # Matches a literal Postgres printed in a plan to the placeholders
      # whose values it could be, after its cast is set aside (the Decided
      # line of 20260922-23). A literal is [kind, text]: kind is :string, a
      # quoted literal, :number, :boolean, or :bits.
      #
      # A string matches a placeholder with exactly its text. It also
      # matches a number-typed placeholder (integer, bigint, or numeric) of
      # the same value, since Postgres prints some numbers quoted, such as
      # '-5'::integer. A number matches a placeholder of the same value,
      # whether the query wrote it as a number or as a string, as in
      # total = '5'. But a string never matches a string by number, so
      # '05' isn't '5'. A boolean matches a boolean placeholder, or a
      # string one Postgres would read as that boolean. Bits match bits.
      #
      # Postgres prints a date, time, or timestamp in its own format, such
      # as '2026-01-01 00:00:00+00' for the query's '2026-01-01', so those
      # often match nothing and are masked.
      class Matcher
        NUMBER_TYPES = %w[integer bigint numeric].freeze
        TYPES = [*NUMBER_TYPES, "boolean", "unknown"].freeze
        DECIMAL = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/
        TRUE_TEXT = %w[t tr tru true y ye yes on 1].freeze
        FALSE_TEXT = %w[f fa fal fals false n no of off 0].freeze

        # map is a placeholder map, as RedactedQuery#placeholder_map gives it
        # and the governed store gives it back. Anything else raises
        # Error bad_placeholder_map.
        def initialize(map)
          raise Error, "bad_placeholder_map" unless map?(map)

          @entries = map.map { |key, entry| [Integer(key[1..]), entry["value"], entry["type"]] }.sort.freeze
        end

        # The numbers of the placeholders the literal could be, lowest first.
        def candidates(literal)
          kind, text = literal
          @entries.filter_map { |number, value, type| number if !value.nil? && match?(kind, text, value, type) }
        end

        private

        def map?(map)
          map.is_a?(Hash) && map.all? do |key, entry|
            key.is_a?(String) && key.match?(/\A\$[1-9]\d*\z/) && entry.is_a?(Hash) &&
              entry.keys.sort == %w[type value] && TYPES.include?(entry["type"]) &&
              (entry["value"].nil? || entry["value"].is_a?(String))
          end
        end

        def match?(kind, text, value, type)
          case kind
          when :string then text == value || (NUMBER_TYPES.include?(type) && same_number?(text, value))
          when :number then %w[unknown].concat(NUMBER_TYPES).include?(type) && same_number?(text, value)
          when :boolean then %w[boolean unknown].include?(type) && boolean(value) == text
          when :bits then type == "unknown" && bits(value) == bits(text)
          else false
          end
        end

        def same_number?(one, other)
          one = number(one)
          !one.nil? && one == number(other)
        end

        def number(text)
          text = text.strip
          Literal.integer(text) || (Rational(text.delete("_")) if text.delete("_").match?(DECIMAL))
        end

        def boolean(text)
          word = text.strip.downcase
          return "true" if TRUE_TEXT.include?(word)

          "false" if FALSE_TEXT.include?(word)
        end

        # A bit string as its bits: pg_query's b101 or x1F, or Postgres's
        # own B'101'. Anything else is nil.
        def bits(text)
          body = text.delete("'")
          case body[0]&.downcase
          when "b" then body[1..] if body[1..].match?(/\A[01]*\z/)
          when "x" then body[1..].chars.map { |c| Integer(c, 16).to_s(2).rjust(4, "0") }.join if body[1..].match?(/\A\h*\z/)
          end
        end
      end

      private_constant :Matcher
    end
  end
end
