# frozen_string_literal: true

require "pg_query"
require_relative "parser_version"
require_relative "function_calls"
require_relative "relation_qualifier"
require_relative "supported_sql"
require_relative "volatility_check_cast_sql"

module Quaack
  module Enclave
    # DESIGN.md's volatility: abort if the query calls a volatile function anywhere,
    # since a volatile function breaks both rewriting and result comparison.
    # The inbound checks for rewrite candidates and index DDL ("What goes
    # into the enclave") call it too, on SQL with $n placeholders, and on
    # an index's expressions and predicate.
    #
    #   VolatilityCheck.check(sql, settings, connection)
    #   # => nil, or raises Error "volatile_function: function pg_catalog.random is volatile"
    #
    # Until input intake (20260922-13) lands, the inputs are the ones
    # RelationQualifier takes: the query text, the Settings hash from the
    # input plan's EXPLAIN (SETTINGS), or nil, and a PG connection to the
    # production database. Only the catalog is read, with plain SELECTs.
    #
    # It checks each call FunctionCalls finds in the parse, which says what
    # that covers and what it can't see. First, the query must use only
    # what SupportedSql lists, or SupportedSql::Error is raised.
    #
    # Picking the overload Postgres would pick takes its full type
    # resolution, so the check doesn't try. It aborts if any candidate
    # could be volatile, and a false abort is the safe mistake:
    #
    # - A function call is volatile if any function of that name that
    #   could take that many arguments, counting defaults and variadic
    #   ones, is volatile, or is an aggregate that calls a volatile
    #   function.
    # - An operator is volatile if any operator of that name and kind,
    #   prefix or binary, has a volatile function.
    # - A cast is volatile if any cast to the type, to its array type, or
    #   to the base type of a domain has a volatile function, or if the
    #   type's input function is volatile. A cast from an unknown literal,
    #   such as 'x'::sometype, calls the input function, and so does a cast
    #   through text, and the parse can't always tell which kind of cast it
    #   is. A cast to a domain also counts the functions its CHECK
    #   constraints call. So one volatile cast to a common type, such as
    #   int, makes every cast to it abort.
    # - A qualified column, t.f, is volatile if any function named f that
    #   takes a row (a composite type, record, anyelement, anycompatible, or "any") as its one argument is,
    #   since it may be attribute notation for f(t).
    #
    # What it doesn't catch: it trusts provolatile, so a function declared
    # STABLE whose body calls nextval is accepted, and its sequence advance
    # survives ROLLBACK. It accepts STABLE functions that read other
    # tables, such as table_to_xml, which is fine in v1 since the rows stay
    # in the enclave. And it can't see what Postgres adds while it analyzes
    # the query (see FunctionCalls).
    #
    # A name with a schema is looked up in that schema only. Any other is
    # looked up in every schema of the plan's search path, which
    # RelationQualifier reads, pg_catalog included. Every schema counts,
    # not just the first with a match, since a match in an earlier schema
    # can lose to a better one in a later schema. When several are
    # volatile, the message names the one in the earliest schema.
    #
    # Anything wrong raises Error, which names the rule it broke. Function,
    # operator, type, and schema names are shape-class, so messages may
    # name them, but a message never quotes the query. A parse error is
    # replaced rather than wrapped, since pg_query's quote the text near
    # the error, which can be a literal.
    module VolatilityCheck
      # function is set only for volatile_function: the schema-qualified
      # name of the volatile function the call reaches, from the catalog.
      # It's schema, so shape, and ErrorFilter sends it on the error line.
      class Error < StandardError
        attr_reader :rule, :function

        def initialize(rule, detail, function: nil)
          @rule = rule
          @function = function
          super("#{rule}: #{detail}")
        end
      end

      # The volatile functions a call could reach: each one's schema and
      # name, and those of the function it resolved to, which differ only
      # for an aggregate's support functions. Every name that's an
      # identifier comes back quoted the way Postgres quotes it, so a
      # message naming it reads only one way. An operator's name is
      # symbols, never quoted. A variadic parameter needs at least one
      # argument, unless it has a default.
      FUNCTION_SQL = <<~SQL
        SELECT pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(p.proname),
               pg_catalog.quote_ident(vn.nspname), pg_catalog.quote_ident(v.proname)
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
        LEFT JOIN pg_catalog.pg_aggregate a ON a.aggfnoid OPERATOR(pg_catalog.=) p.oid
        JOIN pg_catalog.pg_proc v ON v.oid OPERATOR(pg_catalog.=) ANY (ARRAY[p.oid, a.aggtransfn, a.aggfinalfn,
          a.aggcombinefn, a.aggserialfn, a.aggdeserialfn, a.aggmtransfn, a.aggminvtransfn, a.aggmfinalfn])
        JOIN pg_catalog.pg_namespace vn ON vn.oid OPERATOR(pg_catalog.=) v.pronamespace
        WHERE n.nspname OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[]) AND p.proname OPERATOR(pg_catalog.=) $2
          AND v.provolatile OPERATOR(pg_catalog.=) 'v'
          AND $3::int OPERATOR(pg_catalog.>=) (p.pronargs OPERATOR(pg_catalog.-) p.pronargdefaults)
          AND ($3::int OPERATOR(pg_catalog.<=) p.pronargs OR p.provariadic OPERATOR(pg_catalog.<>) 0)
        ORDER BY pg_catalog.array_position($1::pg_catalog.text[], n.nspname::pg_catalog.text), p.oid, v.oid
        LIMIT 1
      SQL

      # t.f can call a function f of one argument, a row: one whose first
      # argument is a composite type, or record, anyelement, anycompatible,
      # or "any", never internal, anyarray, or a handler type. Every schema
      # in the path counts, since the parse doesn't say what t is.
      ATTRIBUTE_SQL = FUNCTION_SQL.sub("ORDER BY", <<~SQL.chomp)
        AND EXISTS (SELECT FROM pg_catalog.pg_type at
                    WHERE at.oid OPERATOR(pg_catalog.=) p.proargtypes[0]
                      AND (at.typtype OPERATOR(pg_catalog.=) 'c' OR at.oid OPERATOR(pg_catalog.=) ANY (ARRAY[
                           'record'::pg_catalog.regtype, 'anyelement'::pg_catalog.regtype,
                           'anycompatible'::pg_catalog.regtype, '"any"'::pg_catalog.regtype]::pg_catalog.oid[])))
        ORDER BY
      SQL

      OPERATOR_SQL = <<~SQL
        SELECT pg_catalog.quote_ident(n.nspname), o.oprname, pg_catalog.quote_ident(fn.nspname),
               pg_catalog.quote_ident(f.proname)
        FROM pg_catalog.pg_operator o
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) o.oprnamespace
        JOIN pg_catalog.pg_proc f ON f.oid OPERATOR(pg_catalog.=) o.oprcode
        JOIN pg_catalog.pg_namespace fn ON fn.oid OPERATOR(pg_catalog.=) f.pronamespace
        WHERE n.nspname OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[]) AND o.oprname OPERATOR(pg_catalog.=) $2
          AND o.oprkind OPERATOR(pg_catalog.=) $3 AND f.provolatile OPERATOR(pg_catalog.=) 'v'
        ORDER BY pg_catalog.array_position($1::pg_catalog.text[], n.nspname::pg_catalog.text), o.oid
        LIMIT 1
      SQL

      SQL_BY_KIND = { function: FUNCTION_SQL, attribute: ATTRIBUTE_SQL, operator: OPERATOR_SQL, cast: CAST_SQL }.freeze

      module_function

      def check(sql, settings, connection) = check_parse(parse(sql), settings, connection)

      # The same check on a parse, for callers that parsed the SQL
      # themselves or built the parse, such as IndexDdlCheck.
      def check_parse(parse, settings, connection)
        SupportedSql.check!(parse)
        path = nil
        FunctionCalls.of(parse.tree).uniq.each do |call|
          schemas = call.schema ? [call.schema] : (path ||= search_path(settings, connection))
          row = volatile(call, schemas, connection)
          raise Error.new("volatile_function", describe(call, row), function: row[2, 2].join(".")) if row
        end
        nil
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", ParserVersion.unparsable("the query doesn't parse")), cause: nil
      end

      def search_path(settings, connection)
        RelationQualifier.search_path(settings, connection)
      rescue RelationQualifier::Error => e
        raise Error.new("bad_search_path", e.message), cause: nil
      end

      def volatile(call, schemas, connection)
        params = [RelationQualifier.text_array(schemas), call.name]
        params << call.arity.to_s if call.arity
        params << "1" if call.kind == :attribute
        rows = connection.exec_params(SQL_BY_KIND.fetch(call.kind), params)
        rows.ntuples.zero? ? nil : rows.values.first
      end

      def describe(call, row)
        schema, name, function_schema, function = row
        called = "#{function_schema}.#{function}"
        case call.kind
        when :function, :attribute
          own = "#{schema}.#{name}"
          own == called ? "function #{own} is volatile" : "function #{own} calls volatile function #{called}"
        when :operator then "operator #{schema}.#{name} calls volatile function #{called}"
        when :cast then "cast to #{schema}.#{name} calls volatile function #{called}"
        end
      end
    end
  end
end
