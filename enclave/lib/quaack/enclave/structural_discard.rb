# frozen_string_literal: true

require_relative "burndown"

module Quaack
  module Enclave
    # README step 8's structural discards: drop the rewrite candidates that
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
    # Each candidate is prepared with the extended protocol, its output
    # columns read with describe, and then planned with EXPLAIN EXECUTE and
    # the literals, so it plans with real values. Any Postgres error on the
    # way, at prepare or at plan, counts as failed_to_plan. The output
    # matches when the count and each column's type OID match, in order.
    # Column names don't matter. The original is described the same way,
    # and an error there raises, since nothing can be compared.
    #
    # record adds the step 8 structural counts to the burndown under the
    # search rewrites, with the inbound check's rejections (README step 8
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

      def check(connection, original:, candidates:, literals:)
        expected = output_types(connection, original)
        raise Error, "the original query doesn't describe on the racetrack", cause: nil unless expected

        dropped = { failed_to_plan: 0, output_mismatch: 0 }
        kept = candidates.select do |sql|
          reason = reason(connection, sql, literals, expected)
          dropped[reason] += 1 if reason
          reason.nil?
        end
        Result.new(kept: kept.freeze, dropped: dropped.freeze)
      end

      def record(store, result, inbound_rejected:)
        dropped = { inbound_check: inbound_rejected, **result.dropped }
        Burndown.record(store, "step8", :rewrites, in: result.kept.size + dropped.values.sum,
                                                   dropped:, out: result.kept.size)
      end

      def reason(connection, sql, literals, expected)
        types = output_types(connection, sql) { planned?(connection, literals) }
        return :failed_to_plan unless types

        :output_mismatch unless types == expected
      end

      # The statement's output type OIDs, or nil on a Postgres error. With
      # a block, it also has to return true while the statement is
      # prepared.
      def output_types(connection, sql)
        connection.prepare(STATEMENT, sql)
        begin
          described = connection.describe_prepared(STATEMENT)
          types = Array.new(described.nfields) { |i| described.ftype(i) }
          types if !block_given? || yield
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
