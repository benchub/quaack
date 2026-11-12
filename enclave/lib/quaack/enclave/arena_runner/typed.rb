# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "../redaction"

module Quaack
  module Enclave
    class ArenaRunner
      # The parameters an arena query written with $n runs with: each value
      # of the Binding, with the type Binding#prepare declares for that
      # query (task 20261110-14). So a $n is typed just as its literal was,
      # 1.5 as numeric against an integer column, and an untyped string as
      # unknown, which Postgres types from where it sits, with the 42P18
      # retry. A placeholder the query doesn't use is declared text.
      #
      #   typed = Typed.new(binding)
      #   typed.params(conn, sql)  # => [{ value: "1.5", type: 1700 }, ...], or [] with no binding
      #
      # Each query's types are worked out once, by a PREPARE whose types are
      # read back from pg_prepared_statements as OIDs, then deallocated, and
      # kept by the query's text. Inside a transaction Binding#prepare runs
      # in a savepoint. When the PREPARE or the read fails, as in an aborted
      # transaction or on a lost connection, the query's types are left to
      # Postgres (OID 0) and nothing is raised, so the query itself fails
      # where it would, through the caller's own error handling (an
      # ArenaRunner::Error with only its SQLSTATE).
      #
      # Trust boundary: the values are the literals, sent only as
      # parameters, never in the SQL's text, and kept in the enclave.
      class Typed
        NAME = "quaack_arena_types"
        TYPES_SQL = "SELECT parameter_types::pg_catalog.oid[]::pg_catalog.text " \
                    "FROM pg_catalog.pg_prepared_statements WHERE name OPERATOR(pg_catalog.=) $1"

        attr_reader :binding

        def initialize(binding)
          @binding = binding
          @oids = {}
        end

        def inspect = "#<#{self.class} values=<redacted>>"

        alias to_s inspect

        def params(conn, sql)
          return [] unless @binding

          oids = @oids[sql] || oids(conn, sql)
          @binding.values.zip(oids).map { |value, type| { value:, type: } }
        end

        private

        # Only types read back are kept, so a failure (an aborted
        # transaction, a brief connection error) is tried again next time
        # rather than leaving the query untyped for good (task 20261110-17).
        # In a transaction the PREPARE, the read, and the DEALLOCATE run in
        # savepoints, so a failed read doesn't abort the caller's
        # transaction. A query that doesn't parse is left to Postgres too.
        def oids(conn, sql)
          @oids[sql] = saved(conn) do
            declared(sql).then { Redaction::Binding.new(sql:, types: it, values: []).prepare(conn, NAME) }
            read(conn)
          end
        rescue Redaction::Error, PG::Error, PgQuery::ParseError
          Array.new(@binding.values.size, 0)
        ensure
          deallocate(conn)
        end

        def saved(conn)
          return yield if conn.transaction_status.zero?

          conn.exec("SAVEPOINT #{NAME}")
          begin
            yield.tap { conn.exec("RELEASE SAVEPOINT #{NAME}") }
          rescue PG::Error
            conn.exec("ROLLBACK TO SAVEPOINT #{NAME}")
            conn.exec("RELEASE SAVEPOINT #{NAME}")
            raise
          end
        end

        # binding's types, with an untyped placeholder sql doesn't use
        # declared text, as Redaction::Binding declares one.
        def declared(sql)
          used = []
          PgQuery.parse(sql).walk! { |_p, _f, node, _l| used << node.number if node.is_a?(PgQuery::ParamRef) }
          @binding.types.each_with_index.map { |type, i| type == "unknown" && !used.include?(i + 1) ? "text" : type }
        end

        def read(conn)
          text = conn.exec_params(TYPES_SQL, [NAME]).getvalue(0, 0)
          text.delete("{}").split(",").map { Integer(it) }
        end

        def deallocate(conn)
          saved(conn) { conn.exec("DEALLOCATE #{NAME}") if conn.exec_params(TYPES_SQL, [NAME]).ntuples.positive? }
        rescue PG::Error
          nil
        end
      end
    end
  end
end
