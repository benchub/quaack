# frozen_string_literal: true

require "pg_query"
require_relative "clock_functions"
require_relative "clock_literals"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # Anchors arena's clock-reading defaults (DESIGN.md's arena-setup), so a
    # counterexamples insert that leaves out such a column, or writes
    # DEFAULT, loads the clock anchor's time, not the wall clock's.
    #
    #   ClockDefaults.anchor(arena)    # => nil, after altering every clock-reading default
    #   ClockDefaults.anchored("now()")  # => "quaack.clock_anchor()", or nil when expr reads no clock
    #
    # Every column default outside the system schemas (generated columns
    # aren't defaults) and every domain default is read back with
    # pg_get_expr under an empty search_path, so only pg_catalog's names
    # are unqualified. In it, these are replaced by the anchor, keeping
    # their type and precision:
    # - now(), transaction_timestamp(), statement_timestamp(), and
    #   clock_timestamp(), unqualified or in pg_catalog, with no arguments.
    # - CURRENT_TIMESTAMP, CURRENT_DATE, CURRENT_TIME, LOCALTIMESTAMP, and
    #   LOCALTIME, with or without a precision.
    # - A clock word ('now', 'today', 'yesterday', 'tomorrow') cast,
    #   possibly through text, to date, timestamp, timestamptz, or ('now'
    #   only) time or timetz, as ('now'::text)::date. A word cast straight
    #   to one of those was read once, when the table was made, and is a
    #   constant already.
    # Anything else is left alone, such as a user function that reads the
    # clock, or timeofday().
    module ClockDefaults
      ANCHOR = ClockFunctions::ANCHOR
      FUNCTIONS = (ClockFunctions::FUNCTIONS + %w[clock_timestamp]).freeze
      TIME_CASTS = { SVFOP_CURRENT_TIME: "pg_catalog.timetz", SVFOP_CURRENT_TIME_N: "pg_catalog.timetz" }.freeze
      TEXT_TYPES = %w[text varchar bpchar].freeze

      SYSTEM_SCHEMAS = <<~SQL.freeze
        n.nspname OPERATOR(pg_catalog.<>) ALL ('{pg_catalog,information_schema}'::pg_catalog.name[])
          AND n.nspname OPERATOR(pg_catalog.!~~) 'pg\\_%'
      SQL
      COLUMN_DEFAULTS_SQL = <<~SQL.freeze
        SELECT n.nspname, c.relname, a.attname, pg_catalog.pg_get_expr(d.adbin, d.adrelid)
        FROM pg_catalog.pg_attrdef d
        JOIN pg_catalog.pg_attribute a
          ON a.attrelid OPERATOR(pg_catalog.=) d.adrelid AND a.attnum OPERATOR(pg_catalog.=) d.adnum
        JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) d.adrelid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE a.attgenerated OPERATOR(pg_catalog.=) '' AND NOT a.attisdropped AND #{SYSTEM_SCHEMAS}
      SQL
      DOMAIN_DEFAULTS_SQL = <<~SQL.freeze
        SELECT n.nspname, t.typname, pg_catalog.pg_get_expr(t.typdefaultbin, 0)
        FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
        WHERE t.typtype OPERATOR(pg_catalog.=) 'd' AND t.typdefaultbin IS NOT NULL AND #{SYSTEM_SCHEMAS}
      SQL

      module_function

      def anchor(conn)
        conn.transaction do
          conn.exec("SET LOCAL search_path = ''")
          conn.exec(COLUMN_DEFAULTS_SQL).each_row do |schema, table, column, expr|
            alter(conn, "TABLE ONLY #{name(conn, schema, table)} ALTER COLUMN #{conn.quote_ident(column)}", expr)
          end
          conn.exec(DOMAIN_DEFAULTS_SQL).each_row do |schema, domain, expr|
            alter(conn, "DOMAIN #{name(conn, schema, domain)}", expr)
          end
        end
        nil
      end

      def alter(conn, target, expr)
        sql = anchored(expr)
        conn.exec("ALTER #{target} SET DEFAULT #{sql}") if sql
      end

      def name(conn, schema, object) = "#{conn.quote_ident(schema)}.#{conn.quote_ident(object)}"

      def anchored(expr)
        tree = PgQuery.parse("SELECT #{expr}").tree
        changed = false
        NodeRewrite.each(tree) { |node| anchored_node(node)&.tap { changed = true } }
        PgQuery.deparse(tree).delete_prefix("SELECT ") if changed
      end

      def anchored_node(node)
        sql = case node.node
              when :func_call then ANCHOR if clock_call?(node.func_call)
              when :sqlvalue_function then sql_value(node.sqlvalue_function)
              when :type_cast then return clock_word_cast(node.type_cast)
              end
        expression(sql) if sql
      end

      def clock_call?(func)
        names = func.funcname.map { |part| part.string.sval }
        ClockFunctions.plain_call?(func) && FUNCTIONS.include?(names.last) &&
          (names.length == 1 || (names.length == 2 && names.first == "pg_catalog"))
      end

      def sql_value(svf)
        cast = TIME_CASTS[svf.op]
        return ClockFunctions.sql_value_anchor(svf) unless cast

        precision = svf.op == :SVFOP_CURRENT_TIME_N ? "(#{Integer(svf.typmod)})" : ""
        "#{ANCHOR}::#{cast}#{precision}"
      end

      def clock_word_cast(cast)
        return unless cast.type_name.array_bounds.empty?

        word = clock_word(cast.arg)
        ClockLiterals.cast(word, cast.type_name) if word && ClockLiterals.castable?(cast.type_name, word)
      end

      # The clock word a cast's argument holds, through casts to text.
      def clock_word(arg)
        arg = arg.type_cast.arg while arg.type_cast && text_cast?(arg.type_cast.type_name)
        ClockLiterals::WORD.match(string_value(arg))&.[](1)&.downcase
      end

      def string_value(node) = node.a_const&.val == :sval ? node.a_const.sval.sval : ""

      def text_cast?(type_name)
        type_name.array_bounds.empty? && TEXT_TYPES.include?(type_name.names.last.string.sval)
      end

      def expression(sql) = ClockLiterals.expression(sql)
    end
  end
end
