# frozen_string_literal: true

require "strscan"

module Quaack
  module Enclave
    # Reads a one-dimensional Postgres array from its text form, the way
    # array_out prints it, into an Array of Strings. It's for pg_stats's
    # anyarray columns cast to text, such as most_common_vals::text:
    #
    #   PgArray.parse('{delivered,"two words","say \"hi\""}')
    #   # => ["delivered", "two words", "say \"hi\""]
    #
    # Each element comes back as the text Postgres printed for it, so a
    # number stays a String ("1.50"), and the caller converts it. A quoted
    # element is unquoted and its backslash escapes undone. An unquoted NULL,
    # in any case, is nil. A quoted "NULL" is the text.
    #
    # It reads only what array_out prints for a one-dimensional array of a
    # type whose delimiter is a comma, which is nearly every type. It raises
    # ArgumentError for a nested (multidimensional) array, bounds decoration
    # like [0:2]={...}, whitespace around elements (which array_in accepts
    # but array_out never prints), and other malformed text. A type with
    # another delimiter parses wrong, without an error: box uses ;, so
    # {(1,1),(0,0);(2,2),(1,1)} splits on its inner commas. A PostGIS
    # geometry MCV list would split the same way, and then fail loudly in
    # ColumnStatistics, whose value and frequency counts no longer match.
    #
    # The text holds real values, so no error message quotes it.
    module PgArray
      QUOTED = /"((?:[^"\\]|\\.)*)"/m
      BARE = /[^,{}"\\\s]+/
      CLOSE = /\}\z/

      module_function

      def parse(text)
        raise ArgumentError, "array text must be a String" unless text.is_a?(String)

        scanner = StringScanner.new(text)
        unreadable unless scanner.skip("{")
        scanner.skip(CLOSE) ? [] : elements(scanner)
      end

      def elements(scanner)
        found = []
        loop do
          found << element(scanner)
          return found if scanner.skip(CLOSE)

          unreadable unless scanner.skip(",")
        end
      end

      def element(scanner)
        return scanner[1].gsub(/\\(.)/m, '\1') if scanner.skip(QUOTED)

        bare = scanner.scan(BARE) or unreadable
        bare unless bare.casecmp?("NULL")
      end

      def unreadable
        raise ArgumentError, "the text isn't a one-dimensional Postgres array"
      end

      private_class_method :elements, :element, :unreadable
    end
  end
end
