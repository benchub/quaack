# frozen_string_literal: true

require "pg_query"
require_relative "relation_qualifier"

module Quaack
  module Enclave
    # InsertCheck's clock_literal rule (task 20260925-2): a counterexample's
    # value mustn't hold 'now', 'today', 'tomorrow', or 'yesterday' where
    # Postgres could read it as a date, time, or timestamp, since that
    # reads the clock, and the fixture would change from run to run.
    #
    #   InsertClockWords.check(cols, rows, column_types, settings, connection)
    #   # => nil, or raises Error "clock_literal: a value for column shipped could read the clock"
    #
    # cols is the insert's column list, rows its VALUES rows (InsertValues
    # has checked them), and column_types each column's type OID by name.
    #
    # A string constant holds a clock word if one is in it as a word of its
    # own, in any case: not next to another letter. Postgres's date and time
    # input reads 'Today', ' now ', 'today 10:00', '10:00,tomorrow', and
    # '"today"' alike. The deterministic special inputs, 'epoch',
    # 'infinity', '-infinity', and 'allballs', are fine.
    #
    # Such a constant is refused if Postgres could read it as a date, time,
    # or timestamp: if it's an argument of a function call, at any depth,
    # since the parse doesn't say which type the function takes there; or
    # if the value's column, or a cast between the constant and the column,
    # is a type that could. A type could if it's date, time, timetz,
    # timestamp, or timestamptz, or a domain, array, range, multirange, or
    # composite type built on one, as tstzrange or date[] is. A cast's type
    # is looked up by name, as the volatility check does: in its schema, or
    # else every schema of the plan's search path, and any type of that name
    # counts. A bad search path is bad_search_path.
    #
    # The message names the rule and the column, never the constant.
    module InsertClockWords
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      WORD = /(?<![a-z])(?:now|today|tomorrow|yesterday)(?![a-z])/i

      # The types of that name in the schemas.
      TYPES_SQL = <<~SQL
        SELECT t.oid FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = ANY ($1::text[]) AND t.typname = $2
      SQL

      # Whether any of the types is a date or time type, or is built on
      # one, all the way down.
      CLOCK_SQL = <<~SQL
        WITH RECURSIVE reached (oid) AS (
          SELECT pg_catalog.unnest($1::pg_catalog.oid[])
          UNION
          SELECT next.oid
          FROM reached
          JOIN pg_catalog.pg_type t ON t.oid = reached.oid
          CROSS JOIN LATERAL (
            SELECT t.typbasetype
            UNION ALL SELECT t.typelem
            UNION ALL SELECT r.rngsubtype FROM pg_catalog.pg_range r WHERE r.rngtypid = t.oid
            UNION ALL SELECT r.rngtypid FROM pg_catalog.pg_range r WHERE r.rngmultitypid = t.oid
            UNION ALL SELECT a.atttypid FROM pg_catalog.pg_attribute a
                      WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped
          ) AS next (oid)
          WHERE next.oid <> 0
        )
        SELECT EXISTS (
          SELECT FROM reached
          WHERE oid IN ('pg_catalog.date'::pg_catalog.regtype, 'pg_catalog.time'::pg_catalog.regtype,
                        'pg_catalog.timetz'::pg_catalog.regtype, 'pg_catalog.timestamp'::pg_catalog.regtype,
                        'pg_catalog.timestamptz'::pg_catalog.regtype)
        )
      SQL

      # A string constant with a clock word: its value's column, the casts
      # between it and the column, and whether it's a function's argument.
      Suspect = Data.define(:column, :casts, :in_call)

      module_function

      def check(cols, rows, column_types, settings, connection)
        path = nil
        lookup = -> { path ||= search_path(settings, connection) }
        refused = all_suspects(cols, rows).find { it.in_call || clock_type?(it, column_types, lookup, connection) }
        raise Error.new("clock_literal", "a value for column #{refused.column} could read the clock") if refused

        nil
      end

      def all_suspects(cols, rows)
        rows.flat_map { |row| cols.zip(row).flat_map { |col, value| suspects(value, col.res_target.name, [], false) } }
      end

      def suspects(node, column, casts, in_call)
        inner = node.inner
        case inner
        when PgQuery::A_Const then WORD.match?(inner.sval&.sval.to_s) ? [Suspect.new(column:, casts:, in_call:)] : []
        when PgQuery::TypeCast then suspects(inner.arg, column, [*casts, inner.type_name], in_call)
        when PgQuery::A_ArrayExpr then inner.elements.flat_map { suspects(it, column, casts, in_call) }
        when PgQuery::FuncCall then inner.args.flat_map { suspects(it, column, casts, true) }
        else []
        end
      end

      # Whether the column's type, or a cast's, could be a date or time
      # type. lookup gives the search path, for unqualified casts.
      def clock_type?(suspect, column_types, lookup, connection)
        oids = [column_types[suspect.column], *suspect.casts.flat_map { cast_types(it, lookup, connection) }]
        connection.exec_params(CLOCK_SQL, ["{#{oids.compact.join(",")}}"]).getvalue(0, 0) == "t"
      end

      def cast_types(type_name, lookup, connection)
        *qualifier, name = type_name.names.map { it.string.sval }
        schemas = qualifier.empty? ? lookup.call : [qualifier.last]
        connection.exec_params(TYPES_SQL, [RelationQualifier.text_array(schemas), name]).column_values(0)
      end

      def search_path(settings, connection)
        RelationQualifier.search_path(settings, connection)
      rescue RelationQualifier::Error => e
        raise Error.new("bad_search_path", e.message), cause: nil
      end
    end
  end
end
