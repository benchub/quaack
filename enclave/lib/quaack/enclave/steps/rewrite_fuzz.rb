# frozen_string_literal: true

require "pg"
require_relative "../arena_runner"
require_relative "../deadline"
require_relative "../fuzz"
require_relative "../rewrite_burndown"

module Quaack
  module Enclave
    module Steps
      # rewrite-test's fuzz search for one stored rewrite (task 20261012-2,
      # DESIGN.md's rewrite-test), which Counterexamples::RewriteTest runs
      # before ScenarioTests, inside the same budget per rewrite.
      #
      #   fuzzed = RewriteFuzz.call(store, "rewrite_2", deadline, -> { arena })
      #   return RewriteFuzz.disproof(fuzzed) if fuzzed.verdict == :disproved
      #
      # call gives Fuzz.run's Outcome, once its burndown is recorded
      # (RewriteBurndown.record_fuzz). The stop rule is
      # Fuzz::StopRule.from_env: the user's rule in production, a trial
      # count for specs, or none, when the search doesn't run and the
      # outcome is untested. A query the search can't take (Fuzz::Error, a
      # statement ArenaRunner refuses, or a failure on the arena) is
      # untested too: ScenarioTests then meets it as it would without fuzz.
      #
      # A disproof's entry carries the rule, its stage, fuzz's trials, and
      # sizes, the shrunk counterexample's rows per table as [schema, table,
      # count]. decided gives a ScenarioTests result its stage and fuzz's
      # trials, and lets a fuzz pass stand for a ScenarioTests that tested
      # nothing: a refusal, or a budget that ran out after fuzz finished.
      # A fuzz run that compared nothing is no pass, so then the rewrite
      # stays refused or out of time.
      #
      # Trust boundary. The worlds, their values, and Postgres's errors and
      # plans stay in Fuzz. What this keeps is the comparison's rule, counts,
      # QUAACK's stage names, and table names, which are schema.
      module RewriteFuzz
        STAGE = "fuzz"
        SCENARIO_TESTS = "rewrite-test"
        UNTESTED = [Fuzz::Error, ArenaRunner::Error, PG::Error, Deadline::Expired].freeze

        module_function

        # connect gives the arena's connection, made only if the search runs.
        def call(store, search, deadline, connect)
          search(store, search, deadline, connect).tap { RewriteBurndown.record_fuzz(store, search, it) }
        end

        def search(store, search, deadline, connect)
          stop = Fuzz::StopRule.from_env(ENV)
          return Fuzz.untested unless stop

          original, candidate = Counterexamples.queries(store, search)
          honour = Counterexamples.honour(store, search)
          Deadline.within(deadline) { Fuzz.run(connect.call, original, candidate, stop:, honour:) }
        rescue *UNTESTED
          Fuzz.untested
        end

        def disproof(outcome)
          { "passed" => false, "scenario" => nil, "rule" => outcome.rule.to_s, "stage" => STAGE,
            "trials" => outcome.trials, "sizes" => outcome.sizes, "untested" => [], "untested_atoms" => [],
            "untested_unchanged" => [] }
        end

        def decided(result, outcome)
          return passed(outcome) if outcome.verdict == :passed && untested?(result)

          result.merge("stage" => SCENARIO_TESTS, "trials" => outcome.trials)
        end

        def untested?(result) = result["refused"] == true || result["rule"] == Protocol::RewriteBudget::RULE

        def passed(outcome)
          { "passed" => true, "scenario" => nil, "rule" => nil, "stage" => STAGE, "trials" => outcome.trials,
            "untested" => [], "untested_atoms" => [], "untested_unchanged" => [] }
        end
      end
    end
  end
end
