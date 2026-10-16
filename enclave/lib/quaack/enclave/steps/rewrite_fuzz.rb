# frozen_string_literal: true

require "pg"
require "quaack/protocol/fuzz_result"
require "quaack/protocol/rewrite_budget"
require_relative "../arena_runner"
require_relative "../atom_position"
require_relative "../deadline"
require_relative "../fuzz"
require_relative "../rewrite_burndown"
require_relative "../rewrite_entry"

module Quaack
  module Enclave
    module Steps
      # rewrite-test's mechanical test of one stored rewrite (DESIGN.md's
      # rewrite-test): the fuzz search (task 20261012-2), then, after a fuzz
      # pass, its enumerate stage (task 20261012-3), inside the rewrite's
      # budget. Counterexamples::RewriteTest runs it.
      #
      #   results = RewriteFuzz.call(store, "rewrite_2", deadline, -> { arena })
      #   RewriteFuzz.record(store, "rewrite_2", results)
      #   RewriteFuzz.result(store, "rewrite_2", results)  # => the rewrite_tested_<n> entry
      #
      # call gives Fuzz.search's Results. The stop rule is
      # Fuzz::StopRule.from_env: the user's rule in production, or a trial
      # count, or none, for specs. Enumerate's limit is
      # Fuzz::Enumerate::Limit.from_env: 30 seconds in production, a count
      # of worlds for specs, or none. The search can only disprove a
      # rewrite, so one it couldn't test isn't disproved (task
      # 20261012-4): it goes on to counterexamples and the later stages as
      # passed, with why as its rule, the report's caution. Fuzz gives its
      # own reasons (Fuzz::REASONS); this adds fuzz_off, for no stop rule,
      # and search_failed, for a query the search can't take (Fuzz::Error,
      # a statement ArenaRunner refuses, a failure on the arena). A
      # deadline that runs out before fuzz compared a world gives
      # out_of_time (Protocol::RewriteBudget), as it has since task
      # 20261011-15; one that runs out after ends fuzz's search as a pass.
      # A cancel QUAACK didn't send, from a lift (ArenaRunner::Cancel.foreign?),
      # ends the step before anything is recorded. An error in enumerate
      # alone leaves fuzz's outcome standing (Fuzz::Search).
      #
      # record stores the burndown (RewriteBurndown.record_fuzz, then
      # record_enumerate unless fuzz disproved the rewrite), the fuzz
      # record marked with each spec setting set (SETTINGS).
      #
      # result's entry carries passed, rule, the stage that decided (fuzz or
      # enumerate), fuzz's trials and fuzz_stop, a pass's
      # Fuzz::StopRule#stopped (task 20261016-4), for the report, not the
      # rewrite_test message, enumerate's worlds and bound, and, for a
      # disproof, sizes, the shrunk counterexample's rows per table as
      # [schema, table, count]. A pass also carries the original's atoms
      # the worlds never showed both true and false (Fuzz::Coverage):
      # untested, their redacted shapes, untested_atoms, their indexes, and
      # untested_unchanged, the shapes of those the rewrite left unchanged
      # (AtomPosition), judged on the unbound SQL so a placeholder's number
      # counts. A shape counts only if every untested atom with that shape
      # is unchanged.
      #
      # Trust boundary. The worlds, their values, and Postgres's errors and
      # plans stay in Fuzz. What this keeps is the comparison's rule,
      # QUAACK's own reason and stage words, counts, why fuzz stopped (a
      # fixed word and whole seconds), table names, which are schema, and
      # redacted atom shapes.
      module RewriteFuzz
        STAGE = "fuzz"
        ENUMERATE = "enumerate"
        FAILED = [Fuzz::Error, ArenaRunner::Error, PG::Error].freeze

        module_function

        # connect gives the arena's connection, made only if the search runs.
        def call(store, search, deadline, connect)
          stop = Fuzz::StopRule.from_env(ENV)
          return Fuzz.unsearched(:fuzz_off) unless stop

          Deadline.within(deadline) do
            Fuzz.search(connect.call, *Counterexamples.queries(store, search), stop:, **options(store, search))
          end
        rescue Deadline::Expired
          Fuzz.unsearched(:out_of_time)
        rescue *FAILED => e
          raise if e.is_a?(ArenaRunner::Error) && ArenaRunner::Cancel.foreign?(e)

          Fuzz.unsearched(:search_failed)
        end

        def options(store, search)
          { enumerate: Fuzz::Enumerate::Limit.from_env(ENV), honour: Counterexamples.honour(store, search) }
        end

        # Records results' burndown.
        def record(store, search, results)
          RewriteBurndown.record_fuzz(store, search, results.fuzz, settings(ENV))
          return if fuzz_disproved?(results)

          RewriteBurndown.record_enumerate(store, search, results.enumerate, untested_atoms(results))
        end

        # The spec settings that limit the searches, by the extra count that
        # marks the fuzz record when each is set, 0 included.
        SETTINGS = { Fuzz::StopRule::ENV_TRIALS => :fuzz_trials_setting,
                     Fuzz::Enumerate::Limit::ENV_WORLDS => :enumerate_worlds_setting }.freeze

        def settings(env) = SETTINGS.filter_map { |name, count| [count, 1] if env.key?(name) }.to_h

        # How many atoms a pass left untested, or nil for no pass.
        def untested_atoms(results)
          results.coverage.untested_atoms.size if passed?(results)
        end

        # The rewrite_tested_<n> entry for results.
        def result(store, search, results)
          return disproof(results) if disproved?(results)
          return untested(results) unless passed?(results)

          passed(store, search, results)
        end

        def fuzz_disproved?(results) = results.fuzz.verdict == :disproved

        def disproved?(results) = fuzz_disproved?(results) || results.enumerate.verdict == :disproved

        def passed?(results) = results.fuzz.verdict == :passed && results.enumerate.verdict != :disproved

        def disproof(results)
          by, stage = fuzz_disproved?(results) ? [results.fuzz, STAGE] : [results.enumerate, ENUMERATE]
          { "passed" => false, "rule" => by.rule.to_s, "stage" => stage, **counts(results), "sizes" => by.sizes,
            **NONE }
        end

        NONE = { "untested" => [], "untested_atoms" => [], "untested_unchanged" => [] }.freeze

        # fuzz's trials and why it stopped, and enumerate's worlds and bound
        # (0 and nil when it didn't run).
        def counts(results)
          { "trials" => results.fuzz.trials, "fuzz_stop" => results.fuzz.stop, "worlds" => results.enumerate.worlds,
            "bound" => results.enumerate.bound }
        end

        # A rewrite the search couldn't test, gone on with why as its rule.
        def untested(results)
          { "passed" => true, "rule" => rule(results.fuzz.reason), "stage" => STAGE, **counts(results), **NONE }
        end

        def rule(reason)
          return Protocol::RewriteBudget::RULE if reason == :out_of_time

          Protocol::FuzzResult::NOT_TESTED.find { it == reason.to_s } || "search_failed"
        end

        def passed(store, search, results)
          stage = results.enumerate.verdict == :passed ? ENUMERATE : STAGE
          coverage = results.coverage
          unchanged = AtomPosition.unchanged_shapes(store.read("anchored_query"),
                                                    RewriteEntry.run_sql(store.read(search)),
                                                    coverage.untested_shapes, coverage.untested_paths)
          { "passed" => true, "rule" => nil, "stage" => stage, **counts(results),
            "untested" => coverage.untested_shapes, "untested_atoms" => coverage.untested_atoms,
            "untested_unchanged" => unchanged }
        end
      end
    end
  end
end
