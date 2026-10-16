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
      # One part, as quote_ident writes it: a bare lowercase name, or a
      # quoted one of printable ASCII whose quote marks are doubled.
      PART = /(?:[a-z_][a-z0-9_$]{0,62}|"(?:[\x20-\x21\x23-\x7e]|""){1,126}")/
      NAME = /\A(#{PART})\.(#{PART})\z/

      module_function

      # Whether field, as JSON reads it back, is an Array of at most MAX
      # Strings, each of NAME's shape. The one check on what it may carry,
      # for the enclave's egress function and the driver both.
      def valid?(field)
        field.is_a?(Array) && field.size <= MAX && field.all? { it.is_a?(String) && NAME.match?(it) }
      end

      # Whether field passes valid? and names only tables, [schema, name]
      # pairs, such as those the report's own query names, so no other
      # relation's name goes out under it.
      def within?(field, tables)
        valid?(field) && field.all? { tables.include?(NAME.match(it).captures.map { unquoted(it) }) }
      end

      def unquoted(part) = part.start_with?('"') ? part[1...-1].gsub('""', '"') : part
    end
  end
end
