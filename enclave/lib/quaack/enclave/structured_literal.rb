# frozen_string_literal: true

require "strscan"

module Quaack
  module Enclave
    # Splits the text form of an array, range, multirange, or composite
    # value into the texts of its parts, the way Postgres's array_in,
    # range_in, multirange_in, and record_in read it, quotes and backslash
    # escapes undone. InsertClockWords uses it to see what each part of a
    # string constant would be read as.
    #
    #   StructuredLiteral.array('[1:2]={a,"b\\"c"}')   # => ["a", "b\"c"]
    #   StructuredLiteral.range('[to\\day,)')          # => ["today", nil]
    #   StructuredLiteral.multirange('{[a,b), empty}')  # => ["[a,b)", "empty"]
    #   StructuredLiteral.record('(1,"x""y",)')         # => ["1", "x\"y", nil]
    #
    # A NULL element or field, or an infinite bound, is nil. A
    # multidimensional array's elements come back flat. Text Postgres
    # wouldn't read raises ArgumentError; so may some text it would, such
    # as an array of a type whose delimiter isn't a comma, and the caller
    # treats that as text it can't see into.
    #
    # The text holds real values, so no error message quotes it.
    module StructuredLiteral
      SPACE = /\s*/
      DIMENSIONS = /\s*(\[\s*[-+]?\d+\s*(:\s*[-+]?\d+\s*)?\]\s*)+=/

      module_function

      def array(text)
        whole(text) do |scanner|
          scanner.skip(DIMENSIONS)
          [].tap { array_level(scanner, it) }
        end
      end

      def array_level(scanner, elements)
        list(scanner, "{", "}") do
          scanner.check(/\{/) ? array_level(scanner, elements) : elements << array_element(scanner)
        end
      end

      def array_element(scanner)
        text, quoted = part(scanner, ",}", doubled: false)
        return text if quoted

        text.rstrip unless text.rstrip.casecmp?("NULL")
      end

      def range(text) = whole(text) { range_bounds(it) }

      def range_bounds(scanner)
        return [] if scanner.skip(/empty/i)

        malformed! unless scanner.skip(/[\[(]/)
        lower = field(scanner, ",")
        expect(scanner, ",")
        upper = field(scanner, "])")
        malformed! unless scanner.skip(/[\])]/)
        [lower, upper]
      end

      def multirange(text)
        whole(text) do |scanner|
          ranges = []
          list(scanner, "{", "}") do
            start = scanner.pos
            range_bounds(scanner)
            ranges << scanner.string[start...scanner.pos]
          end
          ranges
        end
      end

      def record(text)
        whole(text) do |scanner|
          expect(scanner, "(")
          fields = [field(scanner, ",)")]
          fields << field(scanner, ",)") while scanner.skip(/,/)
          expect(scanner, ")")
          fields
        end
      end

      # The block's result for the whole text, with only whitespace around
      # what it reads.
      def whole(text)
        scanner = StringScanner.new(text)
        scanner.skip(SPACE)
        result = yield scanner
        malformed! unless scanner.skip(SPACE) && scanner.eos?
        result
      end

      # Items between open and close, separated by commas, with whitespace
      # around them.
      def list(scanner, open, close)
        expect(scanner, open)
        scanner.skip(SPACE)
        return expect(scanner, close) if scanner.peek(1) == close

        loop do
          yield
          scanner.skip(SPACE)
          return expect(scanner, close) if scanner.peek(1) == close

          expect(scanner, ",")
          scanner.skip(SPACE)
        end
      end

      # A record field or range bound, or nil when it's empty and unquoted.
      def field(scanner, stops)
        text, quoted = part(scanner, stops, doubled: true)
        text.empty? && !quoted ? nil : text
      end

      # The text up to one of the stop characters outside quotes, and
      # whether any of it was quoted. In a record or range, "" in quotes is
      # a quote.
      def part(scanner, stops, doubled:)
        text = +""
        quoted = false
        until scanner.eos? || stops.include?(scanner.peek(1))
          char = scanner.getch
          quoted ||= char == '"'
          text << piece(scanner, char, doubled)
        end
        [text, quoted]
      end

      def piece(scanner, char, doubled)
        case char
        when '"' then quoted_part(scanner, doubled)
        when "\\" then escaped(scanner)
        else char
        end
      end

      # The rest of a quoted part, after its opening quote. escaped reads
      # one character, or fails at the end of the text.
      def quoted_part(scanner, doubled)
        text = +""
        loop do
          char = escaped(scanner)
          return text if char == '"' && !(doubled && scanner.skip(/"/))

          text << (char == "\\" ? escaped(scanner) : char)
        end
      end

      def escaped(scanner) = scanner.getch || malformed!

      def expect(scanner, char) = scanner.peek(1) == char ? scanner.getch : malformed!

      def malformed! = raise(ArgumentError, "malformed structured literal")
    end
  end
end
