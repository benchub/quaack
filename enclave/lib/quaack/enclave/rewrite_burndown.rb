# frozen_string_literal: true

require "quaack/protocol/burndown"
require "quaack/protocol/rewrite_budget"
require_relative "burndown"
require_relative "rewrite_candidate_check"
require_relative "steps/index_search"
require_relative "steps/rewrite_fate"

module Quaack
  module Enclave
    # DESIGN.md's burndown's rewrite stages, as Burndown records: only counts and QUAACK's own rule names.
    #
    # check gives the records of a rewrite-check call with llm-rewrites' or
    # operator-rewrites' rewrites, each under the search rewrites, from its
    # [outcome, stage] pairs, where stage says which stage rejected the
    # rewrite (nil when it was accepted). Each rewrite is dropped in one stage:
    #   llm-rewrites or     added { llm: or operator: every rewrite given },
    #   operator-rewrites   and dropped those refused on arrival (too_many,
    #                       bad_assumption, and RewriteCandidateCheck's
    #                       rules), by rule
    #   assumption-check    dropped unmet_assumption, with extra
    #                       operator_warnings: the warnings on the
    #                       operator's accepted rewrites
    #   plan-pruning        in and dropped StructuralDiscard's and
    #                       ClockAnchoring's rejections, by rule; out is 0,
    #                       since those that go on enter plan-pruning in
    #                       rewrite-prune; no record when there are none
    # The rules are all code constants. One that isn't a burndown name is
    # counted as inbound_check or failed_checks.
    module RewriteBurndown # rubocop:disable Metrics/ModuleLength -- one recorder per stage
      ARRIVAL = { "llm" => "llm-rewrites", "operator" => "operator-rewrites" }.freeze
      # The stage each of RewriteCheck's own rules rejects in.
      OWN = { "too_many" => :arrival, "bad_assumption" => :arrival, "unmet_assumption" => :assumption }.freeze

      module_function

      # Records a rewrite-check call's burndown, check's records, once. For
      # source "rule", also gives the records instead (RewriteCheck.check).
      def record_check(store, source, tagged, also)
        return Burndown.record_once(store, check(source, tagged, carried(store, source))) unless source == "rule"

        more = also.call(tagged.map(&:first), arrived(tagged))
        Burndown.record_all(store, more + later(source, tagged)) if more
      end

      # The stage a RewriteCheck rejection, error, is counted in: RewriteCandidateCheck's rules on arrival,
      # RewriteCheck's own by OWN, and StructuralDiscard's and ClockAnchoring's in plan-pruning.
      def stage(error)
        return :arrival if error.is_a?(RewriteCandidateCheck::Error)

        OWN.fetch(error.rule, :pruning)
      end

      # The arrival stages, in the order they run. Each carries what the
      # nearest earlier one sent on, so its out is every rewrite that has
      # arrived so far (task 20261010-20).
      ARRIVALS = %w[rewrite-rules llm-rewrites operator-rewrites].freeze

      def carried(store, source)
        stages = Burndown.read(store)["stages"]
        ARRIVALS.take_while { it != ARRIVAL.fetch(source) }.reverse
                .lazy.filter_map { stages.dig(it, "rewrites", "out") }.first || 0
      end

      def check(source, tagged, carried)
        arrival = by_rule(tagged, :arrival, :inbound_check)
        [[ARRIVAL.fetch(source), :rewrites, { in: carried, added: { source.to_sym => tagged.size }, dropped: arrival,
                                              out: carried + arrived(tagged) }],
         *later(source, tagged)]
      end

      # How many rewrites got past arrival.
      def arrived(tagged) = tagged.count { it[1] != :arrival }

      # The records of the stages after arrival, which every source's
      # rewrites go through, so one that follows starts where the one before
      # ended.
      def later(source, tagged)
        assumption = tagged.count { it[1] == :assumption }
        [["assumption-check", :rewrites, { in: arrived(tagged), dropped: { unmet_assumption: assumption },
                                           out: arrived(tagged) - assumption, extra: warnings(source, tagged) }],
         pruned(tagged)].compact
      end

      def pruned(tagged)
        pruning = by_rule(tagged, :pruning, :failed_checks)
        ["plan-pruning", :rewrites, { in: pruning.values.sum, dropped: pruning, out: 0 }] if pruning.any?
      end

      # Records fuzz's burndown for search, rewrite_<n> (task 20261012-2,
      # Burndown.record_latest): in 1, and out 1 unless it disproved the
      # rewrite, dropped then by the comparison's rule, a constant of
      # RewriteFate::MISMATCHES (failed for any other). extra trials is how
      # many worlds it compared, and untested 1 says it compared none.
      # outcome is Fuzz.run's.
      def record_fuzz(store, search, outcome)
        disproved = outcome.verdict == :disproved
        untested = outcome.verdict == :untested ? { untested: 1 } : {}
        Burndown.record_latest(
          store, [["fuzz", search.to_sym, { in: 1, dropped: disproved ? { fuzz_drop(outcome.rule) => 1 } : {},
                                            out: disproved ? 0 : 1, extra: { trials: outcome.trials, **untested } }]]
        )
      end

      def fuzz_drop(rule) = Steps::RewriteFate::MISMATCHES.include?(rule.to_s) ? rule.to_sym : :failed

      # Records rewrite-test's burndown for search, rewrite_<n> (Burndown.record_latest): in 1,
      # out 1 if it passed, or dropped by why it didn't (test_drop), with
      # extra untested_atoms and vacuity_guard_retries, and the fixtures it
      # loaded as the total fixture_loads. A rewrite whose test ran out of
      # time goes on (out 1) with extra not_tested_in_time 1. result is the
      # rewrite_tested_<n> entry, and report the ScenarioTests::Report.
      def record_test(store, search, result, report)
        passed = result["passed"]
        Burndown.record_latest(
          store, [["rewrite-test", search.to_sym,
                   { in: 1, dropped: passed ? {} : { test_drop(result) => 1 }, out: passed ? 1 : 0,
                     extra: test_extra(result, report) }]],
          totals: { fixture_loads: report.loads }
        )
      end

      def test_extra(result, report)
        untimed = result["passed"] && result["rule"] == Protocol::RewriteBudget::RULE
        { untested_atoms: report.untested_atoms.size, vacuity_guard_retries: report.retries,
          **({ not_tested_in_time: 1 } if untimed) }
      end

      # Why rewrite-test dropped a rewrite: the scenario that got different
      # results, s0 to s6, or the rule of a scenario that compared nothing or
      # of a refusal to build scenarios, each a constant of RewriteFate's, or
      # out_of_time for a test that ran past its budget (Protocol::RewriteBudget).
      # Anything else is failed.
      def test_drop(result)
        scenario, rule = result.values_at("scenario", "rule")
        return scenario.to_sym if Steps::RewriteFate::MISMATCHES.include?(rule) &&
                                  Steps::RewriteFate::SCENARIOS.include?(scenario)
        return rule.to_sym if Steps::RewriteFate::UNTESTED.include?(rule)

        :failed
      end

      # Records counterexamples' burndown for search, rewrite_<n>
      # (Burndown.record_latest), once survival is decided: in 1, and out 1 for a survivor of the last
      # round, or dropped round_<k> for a mismatch in round k, or
      # failed_in_round_<k> when the round's rule says a statement failed
      # and nothing was compared, as RewriteFate reads it
      # (counterexamples_failed). entry is the last rewrite_round_<n>: the
      # untested atoms its rounds covered are extra atoms_covered, and its
      # fixture loads the total fixture_loads.
      def record_round(store, search, entry, survived:)
        dropped = survived ? {} : { round_drop(entry) => 1 }
        Burndown.record_latest(
          store, [["counterexamples", search.to_sym,
                   { in: 1, dropped:, out: survived ? 1 : 0, extra: { atoms_covered: entry["covered"].size } }]],
          totals: { fixture_loads: entry["fixture_loads"] }
        )
      end

      def round_drop(entry)
        round = Integer(entry["round"])
        failed = Steps::RewriteFate.counterexamples(entry)["fate"] == "counterexamples_failed"
        :"#{"failed_in_" if failed}round_#{round}"
      end

      # Records rewrite-index-ideas' burndown, once, under the search
      # rewrites: the rewrites that reached it (IndexSearch.llm_search?) all
      # go on, since their own index searches drop indexes, never them. Also
      # the total indexes_built, built of them.
      def record_build(store, built)
        reached = measured(store).size
        Burndown.record_once(store, [["rewrite-index-ideas", :rewrites, { in: reached, out: reached }]],
                             totals: { indexes_built: built })
      end

      # The entries that count their measurement runs.
      MEASURED = %w[baseline index_baseline candidate_runs].freeze

      # Records measurement's burndown, once, under the search rewrites:
      # in, the rewrites that reached it (IndexSearch.llm_search?), out,
      # those selection ranked, and the rest dropped by their fate
      # (RewriteFate), with result-comparison's partial comparisons as extra
      # partial_comparisons, and baseline's, index-baseline's, and
      # candidate-runs' runs as the total measurement_runs.
      def record_measurement(store, selection)
        rewrites = measured(store)
        fates = rewrites.empty? ? [] : fates(store, rewrites, selection)
        partial = store.read("result_comparison").fetch("partial_count", 0)
        runs = MEASURED.sum { store.entry?(it) ? store.read(it).fetch("measurement_runs", 0) : 0 }
        Burndown.record_once(
          store, [["measurement", :rewrites, { in: rewrites.size, out: fates.count("ranked"),
                                               dropped: (fates - ["ranked"]).tally.transform_keys(&:to_sym),
                                               extra: { partial_comparisons: partial } }]],
          totals: { measurement_runs: runs }
        )
      end

      def measured(store)
        (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.map { "rewrite_#{it}" }
             .select { Steps::IndexSearch.llm_search?(store, it) }.to_a
      end

      def fates(store, rewrites, selection)
        context = Steps::RewriteFate.context(store, selection:)
        rewrites.map { Steps::RewriteFate.call(store, it, context)["fate"] || "unfinished" }
      end

      def by_rule(tagged, stage, fallback)
        tagged.select { it[1] == stage }.map { name(it[0][:rule], fallback) }.tally
      end

      def name(rule, fallback)
        Protocol::Burndown::NAME.match?(rule.to_s) ? rule.to_s.to_sym : fallback
      end

      def warnings(source, tagged)
        return {} unless source == "operator"

        { operator_warnings: tagged.sum { |outcome, _| outcome[:warnings].size } }
      end
    end
  end
end
