# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # An InitPlan's output as Postgres prints it in a plan's condition,
    # "(InitPlan 1).col1", which pg_query can't parse. It's private to the
    # enclave namespace.
    #
    # as_params gives the text with each one as the parameter $1: the scan
    # reads it as it reads any value its own row doesn't change, and the
    # parameter holds nothing of the plan. The tokens come from pg_query's
    # scanner, so the same text inside a string literal is left alone. Text
    # the scanner can't read, or that isn't a String, comes back as it was,
    # for the parse to refuse.
    module InitPlanOutput
      TOKENS = %i[ASCII_40 IDENT ICONST ASCII_41 ASCII_46 IDENT].freeze # rubocop:disable Naming/VariableNumber

      module_function

      def as_params(text)
        return text unless scannable?(text) && text.include?("InitPlan")

        spans = spans(text, PgQuery.scan(text).first.tokens.to_a)
        spans.reverse.each_with_object(text.b) { |span, out| out[span] = "$1" }.force_encoding(Encoding::UTF_8)
      rescue PgQuery::ScanError
        text
      end

      def scannable?(text) = text.is_a?(String) && text.valid_encoding? && !text.include?("\0")

      # The byte range of each "(InitPlan n).col" in the tokens.
      def spans(text, tokens)
        (0..(tokens.size - TOKENS.size)).filter_map do |i|
          window = tokens[i, TOKENS.size]
          (window.first.start...window.last.end) if match?(text, window)
        end
      end

      def match?(text, window)
        window.map(&:token) == TOKENS && text.byteslice(window[1].start...window[1].end) == "InitPlan"
      end
    end

    private_constant :InitPlanOutput
  end
end
