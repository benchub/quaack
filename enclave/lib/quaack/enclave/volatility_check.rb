# frozen_string_literal: true

require "pg_query"
require_relative "function_calls"
require_relative "relation_qualifier"
require_relative "supported_sql"

module Quaack
  module Enclave
    # README step 3d: abort if the query calls a volatile function anywhere,
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
    #   is.
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
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
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
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        LEFT JOIN pg_catalog.pg_aggregate a ON a.aggfnoid = p.oid
        JOIN pg_catalog.pg_proc v ON v.oid IN (p.oid, a.aggtransfn, a.aggfinalfn, a.aggcombinefn, a.aggserialfn,
                                               a.aggdeserialfn, a.aggmtransfn, a.aggminvtransfn, a.aggmfinalfn)
        JOIN pg_catalog.pg_namespace vn ON vn.oid = v.pronamespace
        WHERE n.nspname = ANY ($1::text[]) AND p.proname = $2 AND v.provolatile = 'v'
          AND $3::int >= p.pronargs - p.pronargdefaults
          AND ($3::int <= p.pronargs OR p.provariadic <> 0)
        ORDER BY pg_catalog.array_position($1::text[], n.nspname::text), p.oid, v.oid
        LIMIT 1
      SQL

      OPERATOR_SQL = <<~SQL
        SELECT pg_catalog.quote_ident(n.nspname), o.oprname, pg_catalog.quote_ident(fn.nspname),
               pg_catalog.quote_ident(f.proname)
        FROM pg_catalog.pg_operator o
        JOIN pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
        JOIN pg_catalog.pg_proc f ON f.oid = o.oprcode
        JOIN pg_catalog.pg_namespace fn ON fn.oid = f.pronamespace
        WHERE n.nspname = ANY ($1::text[]) AND o.oprname = $2 AND o.oprkind = $3 AND f.provolatile = 'v'
        ORDER BY pg_catalog.array_position($1::text[], n.nspname::text), o.oid
        LIMIT 1
      SQL

      # A domain's base type can be another domain, so the base types are
      # followed all the way down.
      CAST_SQL = <<~SQL
        WITH RECURSIVE named AS (
          SELECT t.oid, n.nspname, t.typname
          FROM pg_catalog.pg_type t
          JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname = ANY ($1::text[]) AND t.typname = $2
        ), target (named, oid) AS (
          SELECT oid, oid FROM named
          UNION
          SELECT target.named, t.typbasetype
          FROM target JOIN pg_catalog.pg_type t ON t.oid = target.oid
          WHERE t.typbasetype <> 0
        ), called (named, oid) AS (
          SELECT target.named, c.castfunc
          FROM target
          JOIN pg_catalog.pg_type t ON t.oid = target.oid
          JOIN pg_catalog.pg_cast c ON c.casttarget IN (t.oid, t.typarray)
          UNION ALL
          SELECT target.named, t.typinput::oid
          FROM target JOIN pg_catalog.pg_type t ON t.oid = target.oid
        )
        SELECT pg_catalog.quote_ident(named.nspname), pg_catalog.quote_ident(named.typname),
               pg_catalog.quote_ident(fn.nspname), pg_catalog.quote_ident(f.proname)
        FROM called
        JOIN named ON named.oid = called.named
        JOIN pg_catalog.pg_proc f ON f.oid = called.oid
        JOIN pg_catalog.pg_namespace fn ON fn.oid = f.pronamespace
        WHERE f.provolatile = 'v'
        ORDER BY pg_catalog.array_position($1::text[], named.nspname::text), named.oid, f.oid
        LIMIT 1
      SQL

      SQL_BY_KIND = { function: FUNCTION_SQL, operator: OPERATOR_SQL, cast: CAST_SQL }.freeze

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
          raise Error.new("volatile_function", describe(call, row)) if row
        end
        nil
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", "the query doesn't parse"), cause: nil
      end

      def search_path(settings, connection)
        RelationQualifier.search_path(settings, connection)
      rescue RelationQualifier::Error => e
        raise Error.new("bad_search_path", e.message), cause: nil
      end

      def volatile(call, schemas, connection)
        params = [RelationQualifier.text_array(schemas), call.name]
        params << call.arity.to_s if call.arity
        rows = connection.exec_params(SQL_BY_KIND.fetch(call.kind), params)
        rows.ntuples.zero? ? nil : rows.values.first
      end

      def describe(call, row)
        schema, name, function_schema, function = row
        called = "#{function_schema}.#{function}"
        case call.kind
        when :function
          own = "#{schema}.#{name}"
          own == called ? "function #{own} is volatile" : "function #{own} calls volatile function #{called}"
        when :operator then "operator #{schema}.#{name} calls volatile function #{called}"
        when :cast then "cast to #{schema}.#{name} calls volatile function #{called}"
        end
      end
    end
  end
end
