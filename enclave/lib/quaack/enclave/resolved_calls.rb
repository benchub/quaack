# frozen_string_literal: true

require "pg_query"

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
      Function = Data.define(:schema, :name, :quoted_schema, :quoted_name, :volatility)

      SAVEPOINT = "quaack_resolved_calls"
      VIEW = "quaack_resolved_calls"
      SET_PATH = "SELECT pg_catalog.set_config('search_path', $1, true)"

      # pg_depend has no rows for pg_catalog's pinned functions, so the
      # function ids come from the view's stored tree: each FUNCEXPR
      # written as a call (funcformat 0) or in SQL syntax (3), not the
      # casts (1 and 2) Postgres adds, which the volatility check judges.
      FUNCTIONS_SQL = <<~SQL
        SELECT DISTINCT n.nspname, p.proname, pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(p.proname),
               CASE WHEN p.provolatile OPERATOR(pg_catalog.=) 's' THEN 'stable' ELSE 'volatile' END
        FROM pg_catalog.pg_rewrite r,
             LATERAL pg_catalog.regexp_matches(r.ev_action::pg_catalog.text,
                                               '\\{FUNCEXPR :funcid (\\d+) [^{}]* :funcformat ([03]) ', 'g') m
        JOIN pg_catalog.pg_proc p ON p.oid OPERATOR(pg_catalog.=) m[1]::pg_catalog.oid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
        WHERE r.ev_class OPERATOR(pg_catalog.=) $1::pg_catalog.regclass
          AND p.provolatile OPERATOR(pg_catalog.<>) 'i'
        ORDER BY 1, 2
      SQL

      module_function

      def of(probe, path, connection)
        sql = shell_sql(probe)
        return nil unless sql

        transaction(connection) { functions(sql, path, connection) }
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

      def functions(sql, path, connection)
        connection.exec("SAVEPOINT #{SAVEPOINT}")
        begin
          view!(sql, path, connection)
          connection.exec_params(FUNCTIONS_SQL, ["pg_temp.#{VIEW}"]).values.map { Function.new(*it) }
        rescue PG::Error
          nil
        ensure
          connection.exec("ROLLBACK TO SAVEPOINT #{SAVEPOINT}")
          connection.exec("RELEASE SAVEPOINT #{SAVEPOINT}")
        end
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
