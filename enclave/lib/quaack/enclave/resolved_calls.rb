# frozen_string_literal: true

require "pg_query"
require_relative "coerce_via_io"

module Quaack
  module Enclave
    # The functions Postgres resolves an insert's values to that aren't
    # IMMUTABLE, so InsertValues judges the overload a call picks rather
    # than every overload with that many arguments (20261114-170743-1).
    #
    #   ResolvedCalls.of(probe, path, connection)
    #   # => [Function(schema: "pg_catalog", name: "timezone", ..., volatility: "stable")], or nil
    #
    # probe is InsertValues's SELECT of the values. Postgres shows which
    # overload a call picks only after it analyzes the call, and analysis
    # converts a string literal with its type's input function and a type
    # modifier with the type's typmodin. Neither may run on an LLM's values
    # before the volatility check, so Postgres sees a shell of the values:
    # each string or bit-string constant becomes NULL, which Postgres
    # types as unknown, as it does a string, and converts without an input
    # function; and each cast drops its type modifier, which overload
    # resolution ignores. Numbers and booleans stay, since the parser
    # types and reads them itself. The shell goes into a temporary view,
    # which Postgres analyzes but never plans or runs, so no function in
    # it is called, not even an immutable one on constants. The view's
    # pg_depend rows then name the functions the calls resolved to, and
    # any cast functions Postgres added. It runs in a savepoint, or a
    # transaction of its own, that's rolled back, under the plan's path.
    #
    # It returns nil, and InsertValues falls back to judging by argument
    # count, when the view can't be made: the shell doesn't deparse,
    # Postgres can't resolve a call, or the transaction is read-only. No
    # Postgres error leaves it.
    module ResolvedCalls
      # coercion is true for the output or input function of a cast
      # Postgres does through text (a CoerceViaIO), which no call names.
      Function = Data.define(:schema, :name, :quoted_schema, :quoted_name, :volatility, :coercion)

      SAVEPOINT = "quaack_resolved_calls"
      VIEW = "quaack_resolved_calls"
      SET_PATH = "SELECT pg_catalog.set_config('search_path', $1, true)"

      # pg_depend has no rows for pg_catalog's pinned functions, so the
      # function ids come from the view's stored tree: each FUNCEXPR
      # written as a call (funcformat 0) or in SQL syntax (3). The casts
      # (1 and 2) Postgres adds are left to the volatility check, unless
      # casts: is true, when they come back as coercions: InsertCasts
      # judges the casts the column assignment adds (20261119-001742-1).
      FUNCTIONS_SQL = <<~SQL
        SELECT DISTINCT n.nspname, p.proname, pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(p.proname),
               CASE WHEN p.provolatile OPERATOR(pg_catalog.=) 's' THEN 'stable' ELSE 'volatile' END,
               m[2] OPERATOR(pg_catalog.=) ANY ('{1,2}'::pg_catalog.text[])
        FROM pg_catalog.pg_rewrite r,
             LATERAL pg_catalog.regexp_matches(r.ev_action::pg_catalog.text,
                                               '\\{FUNCEXPR :funcid (\\d+) [^{}]* :funcformat (\\d) ', 'g') m
        JOIN pg_catalog.pg_proc p ON p.oid OPERATOR(pg_catalog.=) m[1]::pg_catalog.oid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
        WHERE r.ev_class OPERATOR(pg_catalog.=) $1::pg_catalog.regclass
          AND p.provolatile OPERATOR(pg_catalog.<>) 'i'
          AND m[2] OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.text[])
        ORDER BY 1, 2
      SQL

      # Raised, with a rule and a message naming only a type, when the
      # shell isn't safe to analyze (20261118-231527-1).
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      # Postgres converts a NULL the shell made to a cast's, a column's,
      # or a parameter's type with that type's input function, and calls
      # it on NULL when it isn't strict. pg_catalog's non-strict ones
      # (domain_in and the pseudo-types') take NULL, but one from C or
      # internal code may crash the backend, so any type outside
      # pg_catalog with one refuses every insert
      # (20261118-231527-1). The parameters' types aren't known before
      # the view resolves the calls, so every type counts.
      LOOSE_INPUT_SQL = <<~SQL
        SELECT pg_catalog.quote_ident(n.nspname) OPERATOR(pg_catalog.||) '.' OPERATOR(pg_catalog.||)
               pg_catalog.quote_ident(t.typname)
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_proc p ON p.oid OPERATOR(pg_catalog.=) t.typinput
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
        WHERE NOT p.proisstrict AND p.pronamespace OPERATOR(pg_catalog.<>) 'pg_catalog'::pg_catalog.regnamespace
        ORDER BY 1 LIMIT 1
      SQL

      module_function

      def loose_input!(connection)
        type = connection.exec(LOOSE_INPUT_SQL).values.first&.first
        raise Error.new("unsafe_input", "type #{type} has an input function that isn't strict") if type
      end

      def of(probe, path, connection, casts: false)
        sql = shell_sql(probe)
        return nil unless sql

        loose_input!(connection)
        formats = casts ? "{0,1,2,3}" : "{0,3}"
        transaction(connection) { functions(sql, path, formats, connection) }
      end

      # The probe's SELECT with its string constants NULL and its casts
      # without type modifiers, each value named, as a view needs, or nil.
      def shell_sql(probe)
        tree = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(probe.tree))
        select = tree.stmts.first.stmt.select_stmt
        select.target_list.each_with_index { |target, i| target.res_target.name = "c#{i + 1}" }
        shell!(select)
        PgQuery.deparse(tree)
      rescue PgQuery::ParseError
        nil
      end

      def shell!(message)
        message.class.descriptor.each { |field| children(field.get(message)).each { shell!(it) } }
        case message
        when PgQuery::A_Const then nulled!(message) if message.sval || message.bsval
        when PgQuery::TypeName then message.typmods.clear
        end
      end

      def children(value)
        values = value.is_a?(Google::Protobuf::RepeatedField) ? value.to_a : [value]
        values.grep(Google::Protobuf::MessageExts)
      end

      def nulled!(constant)
        constant.sval = nil
        constant.bsval = nil
        constant.isnull = true
      end

      def functions(sql, path, formats, connection)
        connection.exec("SAVEPOINT #{SAVEPOINT}")
        begin
          view!(sql, path, connection)
          found(formats, connection).map { Function.new(*it) }
        rescue PG::Error
          nil
        ensure
          connection.exec("ROLLBACK TO SAVEPOINT #{SAVEPOINT}")
          connection.exec("RELEASE SAVEPOINT #{SAVEPOINT}")
        end
      end

      def found(formats, connection)
        view = "pg_temp.#{VIEW}"
        connection.exec_params(FUNCTIONS_SQL, [view, formats]).values + CoerceViaIo.functions(view, connection)
      end

      def view!(sql, path, connection)
        connection.exec_params(SET_PATH, [path.map { connection.quote_ident(it) }.join(", ")])
        connection.exec("CREATE TEMPORARY VIEW #{VIEW} AS #{sql}")
      end

      def transaction(connection)
        return yield unless connection.transaction_status == PG::PQTRANS_IDLE

        connection.exec("BEGIN")
        begin
          yield
        ensure
          connection.exec("ROLLBACK")
        end
      end
    end
  end
end
