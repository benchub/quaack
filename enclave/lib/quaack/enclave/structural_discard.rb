# frozen_string_literal: true

require_relative "burndown"
require_relative "redaction"

module Quaack
  module Enclave
    # DESIGN.md step 8's structural discards: drop the rewrite candidates that
    # fail to plan on the racetrack, or whose output column count or types
    # differ from the original's.
    #
    #   result = StructuralDiscard.check(connection, original: sql, candidates: [sql, ...], literals: ["open"])
    #   # => Result(kept: [sql, ...], dropped: { failed_to_plan: 1, output_mismatch: 0 })
    #   StructuralDiscard.record(store, result, inbound_rejected: 2)
    #
    # connection is a live racetrack connection, not inside a transaction.
    # original and each candidate are one statement with the original's $n
    # placeholders, as RewriteCandidateCheck accepts them. literals are the
    # slow literal set's values, in parameter order, each a String or nil.
    # Each candidate is prepared with the extended protocol and the
    # original's parameter types (param_types), so one that leaves out a
    # placeholder, or uses one where its type can't be inferred, reads it
    # as the original does. Its output
    # columns read with describe, and then planned with EXPLAIN EXECUTE and
    # the literals, so it plans with real values. Any Postgres error on the
    # way, at prepare or at plan, counts as failed_to_plan. The output
    # matches when the count and each column's type OID match, in order.
    # Column names don't matter. The original is described the same way,
    # and an error there raises, since nothing can be compared.
    #
    # record adds the step 8 structural counts to the burndown under the
    # search rewrites, with the inbound check's rejections (DESIGN.md step 8
    # counts them here) as inbound_check.
    #
    # Trust boundary. Result holds the candidates' own text, which has
    # placeholders, not literals, and counts. The literals go only to the
    # racetrack, and no Postgres error message is kept.
    module StructuralDiscard
      class Error < StandardError; end

      Result = Data.define(:kept, :dropped)

      STATEMENT = "quaack_step8"

      module_function

      def check(connection, original:, candidates:, literals:, types: nil)
        param_types = parameter_types(connection, original, types)
        expected = param_types && output_types(connection, original, param_types:)
        raise Error, "the original query doesn't describe on the racetrack", cause: nil unless expected

        dropped = { failed_to_plan: 0, output_mismatch: 0 }
        kept = candidates.select do |sql|
          reason = reason(connection, sql, literals, expected, param_types:)
          dropped[reason] += 1 if reason
          reason.nil?
        end
        Result.new(kept: kept.freeze, dropped: dropped.freeze)
      end

      def record(store, result, inbound_rejected:)
        Burndown.record_all(store, [stage_record(result, inbound_rejected:)])
      end

      # What record records, as a [stage, search, counts] triple for
      # Burndown.record_all, for a caller that stores it with other stages'.
      def stage_record(result, inbound_rejected:)
        dropped = { inbound_check: inbound_rejected, **result.dropped }
        ["step8", :rewrites, { in: result.kept.size + dropped.values.sum, dropped:, out: result.kept.size }]
      end

      def reason(connection, sql, literals, expected, param_types: [])
        types = output_types(connection, sql, param_types:) { planned?(connection, literals) }
        return :failed_to_plan unless types

        :output_mismatch unless types == expected
      end

      # The statement's output type OIDs, or nil on a Postgres error. With
      # a block, it also has to return true while the statement is
      # prepared.
      def output_types(connection, sql, param_types: [], &plan)
        described(connection, sql, param_types, plan) { |d| Array.new(d.nfields) { |i| d.ftype(i) } }
      end

      # The statement's parameter type OIDs, in $n order, or nil on a
      # Postgres error. With types, the type names of its literals (see
      # Redaction::Binding), each $n is declared as its literal was, so
      # Postgres doesn't infer another type from context. Without,
      # Postgres infers them all.
      def parameter_types(connection, sql, types = nil)
        return described(connection, sql, [], nil) { |d| param_oids(d) } unless types

        Redaction.prepare(connection, STATEMENT, sql, types)
        begin
          param_oids(connection.describe_prepared(STATEMENT))
        ensure
          connection.exec("DEALLOCATE #{STATEMENT}")
        end
      rescue Redaction::Error
        nil
      end

      def param_oids(description) = Array.new(description.nparams) { |i| description.paramtype(i) }

      # The block's result for the prepared statement's description, or nil
      # on a Postgres error or when plan, if given, returns false.
      def described(connection, sql, param_types, plan)
        connection.prepare(STATEMENT, sql, param_types)
        begin
          result = yield connection.describe_prepared(STATEMENT)
          result if plan.nil? || plan.call
        ensure
          connection.exec("DEALLOCATE #{STATEMENT}")
        end
      rescue PG::Error
        nil
      end

      def planned?(connection, literals)
        values = literals.map { |v| v.nil? ? "NULL" : connection.escape_literal(v) }
        execute = values.empty? ? STATEMENT : "#{STATEMENT}(#{values.join(", ")})"
        connection.exec("EXPLAIN (FORMAT JSON) EXECUTE #{execute}")
        true
      rescue PG::Error
        false
      end
    end
  end
end
