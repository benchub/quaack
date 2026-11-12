# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of the report's tablespace_moves (DESIGN.md's run-server and
    # report): the query's tables that sit in another tablespace on the run
    # server than in production, which run-server warns of and doesn't
    # refuse. Each is a table's schema.name, as Postgres's quote_ident
    # writes each part, which is schema. A tablespace's name is production
    # configuration and never goes out.
    module TablespaceMoves
      MAX = 64
      # Postgres keeps at most this many bytes of a name (NAMEDATALEN - 1).
      NAME_BYTES = 63
      # One character of a quoted part other than a quote mark: printable
      # ASCII, or a non-ASCII character that is neither a control, format,
      # surrogate, private-use or unassigned character (\p{C}, which holds
      # C1 controls, bidi overrides and isolates, and zero-width ones) nor a
      # separator (\p{Z}, which holds U+2028, U+2029 and no-break spaces).
      QUOTED_CHAR = /[\x20-\x21\x23-\x7e]|[^\x00-\x7f\p{C}\p{Z}]/
      # One part, as quote_ident writes it: a bare lowercase ASCII name, or a
      # quoted one of QUOTED_CHARs whose quote marks are doubled.
      PART = /(?:[a-z_][a-z0-9_$]{0,62}|"(?:#{QUOTED_CHAR}|""){1,126}")/
      NAME = /\A(#{PART})\.(#{PART})\z/

      module_function

      # Whether field, as JSON reads it back, is an Array of at most MAX
      # Strings, each valid UTF-8 of NAME's shape whose parts, unquoted, are
      # each at most NAME_BYTES bytes. The one check on what it may carry,
      # for the enclave's egress function and the driver both.
      def valid?(field)
        field.is_a?(Array) && field.size <= MAX && field.all? { name?(it) }
      end

      def name?(value)
        return false unless value.is_a?(String)

        text = value.dup.force_encoding(Encoding::UTF_8)
        return false unless text.valid_encoding?

        parts = NAME.match(text)&.captures or return false
        parts.all? { unquoted(it).bytesize <= NAME_BYTES }
      end

      # Whether field passes valid? and names only tables, [schema, name]
      # pairs, such as those the report's own query names, so no other
      # relation's name goes out under it.
      def within?(field, tables)
        valid?(field) && field.all? { tables.include?(parts(it).map { unquoted(it) }) }
      end

      def parts(name) = NAME.match(name.dup.force_encoding(Encoding::UTF_8)).captures

      def unquoted(part) = part.start_with?('"') ? part[1...-1].gsub('""', '"') : part
    end
  end
end
