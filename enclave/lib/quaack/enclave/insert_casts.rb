# frozen_string_literal: true

require "pg_query"
require_relative "coerce_via_io"
require_relative "insert_values"
require_relative "resolved_calls"

module Quaack
  module Enclave
    # InsertCheck's not_immutable rule for casts (rule 14, task
    # 20261118-223225-2): a cast Postgres does through text, the
    # assignment to the column included, runs a type's output or input
    # function, which must be IMMUTABLE.
    #
    #   InsertCasts.check(cols, rows, types, settings, connection)
    #   # => nil, or raises InsertValues::Error "not_immutable: function pg_catalog.timestamptz_out is stable, ..."
    module InsertCasts
      # A column type's schema and name, as a cast to it names them.
      TYPE_SQL = <<~SQL
        SELECT n.nspname, t.typname FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
        WHERE t.oid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
      SQL

      module_function

      # Each value is cast to its column's type, so the assignment shows
      # as a cast as well. cols is the INSERT's column list, types each
      # column's type OID by name.
      def check(cols, rows, types, settings, connection)
        names = cols.map { type_name(types.fetch(it.res_target.name), connection) }
        coercions!(InsertValues.probe(rows.map { |row| row.zip(names).map { |value, name| assigned(value, name) } }),
                   settings, connection)
        nil
      end

      def assigned(value, name)
        return value if value.node == :set_to_default

        PgQuery::Node.from(PgQuery::TypeCast.new(arg: value, type_name: name))
      end

      def type_name(oid, connection)
        names = connection.exec_params(TYPE_SQL, [oid]).values.first
        PgQuery::TypeName.new(names: names.map { PgQuery::Node.from(PgQuery::String.new(sval: it)) })
      end

      # A cast Postgres does through text runs a type's output and input
      # functions, which no call names, so they're judged here
      # (20261118-223225-2). It comes after the volatility check, since
      # ResolvedCalls' view may run a cast's input function on NULL.
      def coercions!(probe, settings, connection)
        return unless CoerceViaIo.casts?(probe.tree)

        # A cast with a function, such as date(timestamptz), counts too
        # (20261119-001742-1).
        path = InsertValues.search_path(settings, connection)
        coercion = ResolvedCalls.of(probe, path, connection, casts: true)&.find(&:coercion)
        InsertValues.refuse!(coercion.quoted_schema, coercion.quoted_name, coercion.volatility) if coercion
      end
    end
  end
end
