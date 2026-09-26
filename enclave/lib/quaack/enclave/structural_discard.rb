# frozen_string_literal: true

module Quaack
  module Enclave
    # Step 8's structural discards for one rewrite candidate, on the
    # racetrack (README step 8):
    #
    #   StructuralDiscard.check(candidate_sql, original_sql, connection)
    #   # => ["text", "integer"], the candidate's output column types
    #   # or raises Error with rule plan_failed, column_count_mismatch, or
    #   # column_type_mismatch
    #
    # Both SQL texts use $n placeholders. The original is prepared first,
    # and its parameter types, from pg_prepared_statements, are the ones the
    # candidate is prepared with, so both read the placeholders the same way.
    # The candidate must then plan: EXPLAIN EXECUTE with every parameter
    # NULL, under a forced generic plan, in a transaction that's rolled back.
    # Then its result_types must match the original's in count and in order.
    #
    # candidate_sql must already have passed RewriteCandidateCheck, so it's
    # one plain SELECT. A Postgres error can quote the SQL, so it's never
    # kept: Error names only the rule, and has no cause.
    module StructuralDiscard
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      ORIGINAL = "quaack_structural_original"
      CANDIDATE = "quaack_structural_candidate"

      TYPES_SQL = <<~SQL
        SELECT t::text FROM pg_catalog.pg_prepared_statements, unnest(%s) WITH ORDINALITY AS u(t, n)
        WHERE name = $1 ORDER BY n
      SQL

      module_function

      def check(candidate_sql, original_sql, connection)
        connection.exec("PREPARE #{ORIGINAL} AS #{original_sql}")
        parameters = types(connection, ORIGINAL, "parameter_types")
        expected = types(connection, ORIGINAL, "result_types")
        actual = plan(candidate_sql, parameters, connection)
        raise Error, "column_count_mismatch" unless actual.size == expected.size
        raise Error, "column_type_mismatch" unless actual == expected

        actual
      ensure
        connection.exec("DEALLOCATE ALL")
      end

      def plan(sql, parameters, connection)
        types = parameters.empty? ? "" : "(#{parameters.join(", ")})"
        connection.exec("PREPARE #{CANDIDATE}#{types} AS #{sql}")
        connection.transaction do
          connection.exec("SET LOCAL plan_cache_mode = force_generic_plan")
          nulls = parameters.empty? ? "" : "(#{Array.new(parameters.size, "NULL").join(", ")})"
          connection.exec("EXPLAIN EXECUTE #{CANDIDATE}#{nulls}")
        end
        types(connection, CANDIDATE, "result_types")
      rescue PG::Error
        raise Error, "plan_failed", cause: nil
      end

      def types(connection, name, column)
        connection.exec_params(format(TYPES_SQL, column), [name]).column_values(0)
      end
    end
  end
end
