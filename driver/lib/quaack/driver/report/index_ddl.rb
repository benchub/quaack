# frozen_string_literal: true

require "pg_query"

module Quaack
  module Driver
    module Report
      # A built index's CREATE INDEX ON in pieces, from pg_query's scanner,
      # which reads a quoted table name whole, even one with a space or
      # USING in it. The DDL can hold ? for a redacted value, which the
      # scanner reads and the parser wouldn't.
      #
      #   IndexDdl.parts('CREATE INDEX ON public."my t" USING gin (b)')
      #   # => ['public."my t" USING gin (b)', 'public."my t"', "gin", "(b)"]
      module IndexDdl
        # A piece of a table's name that isn't a name or a keyword: the dot.
        DOT = "."
        START = %i[CREATE INDEX ON].freeze

        module_function

        # What follows ON, the table, the method, and what follows the
        # method, or nil for any other DDL. The scanner counts in bytes, so
        # the pieces are cut in bytes.
        def parts(ddl)
          tokens = PgQuery.scan(ddl).first.tokens
          using = tokens.index { it.token == :USING }
          pieces(ddl, tokens[3].start, tokens[using].start, tokens[using + 1]) if using && shaped?(ddl, tokens, using)
        rescue PgQuery::ScanError
          nil
        end

        # The pieces, from where the table starts, where USING does, and
        # the method's token.
        def pieces(ddl, on, using, method)
          [cut(ddl, on), cut(ddl, on, using), cut(ddl, method.start, method.end), cut(ddl, method.end)]
        end

        # CREATE INDEX ON, a table's name, USING, and a method's name.
        def shaped?(ddl, tokens, using)
          tokens.first(3).map(&:token) == START && tokens[using + 1]&.token == :IDENT &&
            tokens[3...using].all? { name?(ddl, it) }
        end

        # A piece of a table's name: a name, a keyword used as one, or the
        # dot between a schema and a table.
        def name?(ddl, token)
          token.token == :IDENT || token.keyword_kind != :NO_KEYWORD || cut(ddl, token.start, token.end) == DOT
        end

        def cut(ddl, from, to = ddl.bytesize) = ddl.byteslice(from...to).strip
      end
    end
  end
end
