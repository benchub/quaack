# frozen_string_literal: true

require "pg_query"
require_relative "../../function_calls"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # Catalog facts about the functions and operators an expression
        # calls, for a rule that moves an expression past a join. Each answer
        # is kept for the life of the Catalog.
        module Calls
          # A function of the name, in the schema if the call names one and
          # in any schema if not, that returns a set or is an aggregate or a
          # window function.
          FUNCTIONS = <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
              WHERE p.proname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2)
                AND (p.proretset OR p.prokind OPERATOR(pg_catalog.<>) 'f'))
          SQL

          # Functions of the name, in the schema if the call names one and in
          # any schema if not, of which there's one and all are aggregates.
          AGGREGATES = <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
              WHERE p.proname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2)
                AND p.prokind OPERATOR(pg_catalog.=) 'a')
            AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
              WHERE p.proname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2)
                AND p.prokind OPERATOR(pg_catalog.<>) 'a')
          SQL

          # Functions of the name, in the schema if the call names one and in
          # any schema if not, of which there's one and all are pg_catalog's
          # own aggregates.
          BUILTIN_AGGREGATES = <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
              WHERE p.proname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2))
            AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
              WHERE p.proname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2)
                AND (p.prokind OPERATOR(pg_catalog.<>) 'a' OR n.nspname OPERATOR(pg_catalog.<>) 'pg_catalog'))
          SQL

          # An operator of the name, likewise, whose function returns a set.
          OPERATORS = <<~SQL
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_operator o
              JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) o.oprnamespace
              JOIN pg_catalog.pg_proc p ON p.oid OPERATOR(pg_catalog.=) o.oprcode
              WHERE o.oprname OPERATOR(pg_catalog.=) $1
                AND ($2::pg_catalog.text IS NULL OR n.nspname OPERATOR(pg_catalog.=) $2) AND p.proretset)
          SQL

          # Whether every function and operator nodes call, by FunctionCalls,
          # gives one value for each row it's given: no function or operator
          # it could reach returns a set, and no function it could reach is
          # an aggregate or window function. Which overload Postgres would
          # pick isn't worked out, so one such of the name is enough to say
          # no. A cast's function can't return a set, and an aggregate's
          # call is a function's, so casts aren't looked up.
          def row_wise?(nodes)
            @many ||= {}
            calls = nodes.flat_map { FunctionCalls.of(it) }.select { %i[function operator].include?(it.kind) }
            calls.none? do |call|
              key = [call.kind, call.schema, call.name]
              @many.fetch(key) { @many[key] = many?(call) }
            end
          end

          # Whether a call of the function, by name and schema (nil if the
          # call names none), is an aggregate however Postgres reads it: at
          # least one function of the name is one and none is anything else.
          def only_aggregates?(schema, name)
            @aggregates ||= {}
            @aggregates.fetch([schema, name]) do
              @aggregates[[schema, name]] = @connection.exec_params(AGGREGATES, [name, schema]).getvalue(0, 0) == "t"
            end
          end

          # Whether a call of the function, by name and schema (nil if the
          # call names none), is one of pg_catalog's own aggregates however
          # Postgres reads it: no schema has another function of the name.
          def builtin_aggregate?(schema, name)
            @builtin_aggregates ||= {}
            @builtin_aggregates.fetch([schema, name]) do
              @builtin_aggregates[[schema, name]] =
                @connection.exec_params(BUILTIN_AGGREGATES, [name, schema]).getvalue(0, 0) == "t"
            end
          end

          private

          def many?(call)
            sql = call.kind == :function ? FUNCTIONS : OPERATORS
            @connection.exec_params(sql, [call.name, call.schema]).getvalue(0, 0) == "t"
          end
        end
      end
    end
  end
end
