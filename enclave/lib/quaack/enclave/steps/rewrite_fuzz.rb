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
      # DESIGN.md's rewrite-test), then, after a fuzz pass, its enumerate
      # stage (task 20261012-3), which Counterexamples::RewriteTest runs
      # before ScenarioTests, inside the same budget per rewrite.
      #
      #   fuzzed = RewriteFuzz.call(store, "rewrite_2", deadline, -> { arena })
      #   return RewriteFuzz.disproof(fuzzed) if RewriteFuzz.disproved?(fuzzed)
      #
      # call gives Fuzz.search's Results, once their burndown is recorded
      # (RewriteBurndown.record_fuzz, then record_enumerate unless fuzz
      # disproved the rewrite). The stop rule is Fuzz::StopRule.from_env:
      # the user's rule in production, a trial count for specs, or none,
      # when neither search runs and both outcomes are untested.
      # Enumerate's limit is Fuzz::Enumerate::Limit.from_env: 30 seconds in
      # production, a count of worlds for specs, or none. A query the search
      # can't take (Fuzz::Error, a statement ArenaRunner refuses, or a
      # failure on the arena) is untested too: ScenarioTests then meets it
      # as it would without fuzz. A cancel QUAACK didn't send, from a lift
      # (ArenaRunner::Cancel.foreign?), isn't: it ends the step, as it does
      # in ScenarioTests, before any burndown is recorded. An error in
      # enumerate alone leaves fuzz's outcome standing (Fuzz::Search).
      #
      # A disproof's entry carries the rule, the stage that found it (fuzz
      # or enumerate), fuzz's trials, enumerate's worlds and bound, and
      # sizes, the shrunk counterexample's rows per table as [schema, table,
      # count]. decided gives a ScenarioTests result its stage and those
      # counts, and lets a fuzz or enumerate pass stand for a ScenarioTests
      # that tested nothing: a refusal, or a budget that ran out after the
      # search finished. Its stage is then enumerate if enumerate passed,
      # else fuzz. A fuzz run that compared nothing is no pass, so then the
      # rewrite stays refused or out of time.
      #
      # Trust boundary. The worlds, their values, and Postgres's errors and
      # plans stay in Fuzz. What this keeps is the comparison's rule, counts,
      # QUAACK's stage names, and table names, which are schema.
      module RewriteFuzz
        STAGE = "fuzz"
        ENUMERATE = "enumerate"
        SCENARIO_TESTS = "rewrite-test"
        UNTESTED = [Fuzz::Error, ArenaRunner::Error, PG::Error, Deadline::Expired].freeze

        module_function

        # connect gives the arena's connection, made only if the search runs.
        def call(store, search, deadline, connect)
          search(store, search, deadline, connect).tap do |results|
            RewriteBurndown.record_fuzz(store, search, results.fuzz)
            RewriteBurndown.record_enumerate(store, search, results.enumerate) unless fuzz_disproved?(results)
          end
        end

        def search(store, search, deadline, connect)
          stop = Fuzz::StopRule.from_env(ENV)
          return untested unless stop

          limit = Fuzz::Enumerate::Limit.from_env(ENV)
          original, candidate = Counterexamples.queries(store, search)
          honour = Counterexamples.honour(store, search)
          Deadline.within(deadline) do
            Fuzz.search(connect.call, original, candidate, stop:, enumerate: limit, honour:)
          end
        rescue *UNTESTED => e
          untested_after(e)
        end

        def untested = Fuzz::Results.new(fuzz: Fuzz.untested, enumerate: Fuzz::Enumerate.untested)

        # Both untested, or error raised again if it's a cancel QUAACK didn't send.
        def untested_after(error)
          raise error if error.is_a?(ArenaRunner::Error) && ArenaRunner::Cancel.foreign?(error)

          untested
        end

        def fuzz_disproved?(results) = results.fuzz.verdict == :disproved

        def disproved?(results) = fuzz_disproved?(results) || results.enumerate.verdict == :disproved

        def disproof(results)
          by, stage = fuzz_disproved?(results) ? [results.fuzz, STAGE] : [results.enumerate, ENUMERATE]
          { "passed" => false, "scenario" => nil, "rule" => by.rule.to_s, "stage" => stage, **counts(results),
            "sizes" => by.sizes, "untested" => [], "untested_atoms" => [], "untested_unchanged" => [] }
        end

        # fuzz's trials, and enumerate's worlds and bound (0 and nil when it didn't run).
        def counts(results)
          { "trials" => results.fuzz.trials, "worlds" => results.enumerate.worlds, "bound" => results.enumerate.bound }
        end

        def decided(result, results)
          return passed(results) if results.fuzz.verdict == :passed && untested?(result)

          result.merge("stage" => SCENARIO_TESTS, **counts(results))
        end

        def untested?(result) = result["refused"] == true || result["rule"] == Protocol::RewriteBudget::RULE

        def passed(results)
          stage = results.enumerate.verdict == :passed ? ENUMERATE : STAGE
          { "passed" => true, "scenario" => nil, "rule" => nil, "stage" => stage, **counts(results),
            "untested" => [], "untested_atoms" => [], "untested_unchanged" => [] }
        end
      end
    end
  end
end
