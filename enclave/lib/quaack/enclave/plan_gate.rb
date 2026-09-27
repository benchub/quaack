# frozen_string_literal: true

require_relative "canonical_plan"
require_relative "redaction"
require_relative "single_candidate_test"

module Quaack
  module Enclave
    # README 5: the plan gate. EXPLAIN the original query on the racetrack
    # with the slow literals, and abort unless its canonical form matches
    # the step 1 plan's.
    #
    #   PlanGate.check(store:, connection:, sql: anchored_sql)  # nil, or raises an Error
    #
    # sql is the query step 5 runs: the redacted query (3g, with $n where
    # the literals were) after 3h anchored it, so it calls
    # quaack.clock_anchor() where production called now(). It must bind
    # against the stored placeholder map (see Redaction.binding), or
    # Redaction::Error is raised. The slow literals are that map's values,
    # which are the slow set of 3e. connection is a racetrack connection
    # after Racetrack.setup, not inside a transaction.
    #
    # The EXPLAIN is SingleCandidateTest's baseline, with no candidate: a
    # custom plan for the slow literals, prepared afresh, inside a
    # transaction that's rolled back, with notices dropped. So it's the
    # same plan 5a-4 starts from. Its errors (SingleCandidateTest::Error)
    # pass through.
    #
    # The step 1 plan is the stored plan entry. CanonicalPlan compares a
    # clock function in it as 3h's anchor, so the anchored query's plan
    # can match it.
    #
    # Errors, by rule. Each fails closed:
    # - plan_gate_bad_plan: the stored plan isn't EXPLAIN (FORMAT JSON)
    #   output.
    # - plan_gate_not_comparable: either plan has a qual CanonicalPlan
    #   can't compare, so the gate can't tell whether they match.
    # - plan_gate_mismatch_likely_stale_statistics: the plans differ. The
    #   rule names the likely cause, since only the rule leaves the
    #   enclave: the racetrack's statistics don't match production's, as
    #   when the backup is older than 3c's statistics.
    #
    # Trust boundary: both plans hold real literals and stay here. An
    # Error's message is fixed text, its rule and an explanation, and it
    # has no cause.
    module PlanGate
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail = nil)
          @rule = rule
          super(detail ? "#{rule}: #{detail}" : rule)
        end
      end

      MISMATCH = "plan_gate_mismatch_likely_stale_statistics"

      MISMATCH_DETAIL = "the racetrack's plan for the slow literals doesn't match the step 1 plan. The likely " \
                        "cause is that the racetrack's statistics don't match production's, such as a backup " \
                        "older than the statistics from 3c. Restore a fresh backup, or ANALYZE, and run again."

      NOT_COMPARABLE_DETAIL = "a plan has a condition the canonical form can't compare, so the gate can't " \
                              "tell whether the racetrack plans like production"

      module_function

      def check(store:, connection:, sql:)
        production = step1_plan(store)
        map = Redaction.placeholder_map(store)
        types = Redaction.binding(sql, map).types
        racetrack = racetrack_plan(connection, sql, map, types)
        comparable = production.comparable? && racetrack.comparable?
        raise Error.new("plan_gate_not_comparable", NOT_COMPARABLE_DETAIL) unless comparable
        raise Error.new(MISMATCH, MISMATCH_DETAIL) unless production.matches?(racetrack)

        nil
      end

      def step1_plan(store)
        CanonicalPlan.new(store.read("plan"))
      rescue ArgumentError
        raise Error, "plan_gate_bad_plan", cause: nil
      end

      # The slow literals, in parameter order, as SingleCandidateTest takes
      # them.
      def racetrack_plan(connection, sql, map, types)
        values = map.keys.sort_by { |key| Integer(key.delete_prefix("$")) }.map { |key| map[key]["value"] }
        report = SingleCandidateTest.run(connection, query: sql, literal_sets: { slow: values }, candidates: [], types:)
        report.baseline.plans.fetch(:slow).canonical_plan
      end
    end
  end
end
