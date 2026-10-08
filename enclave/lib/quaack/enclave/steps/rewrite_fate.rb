# frozen_string_literal: true

require_relative "../result_comparator"
require_relative "../scenarios"
require_relative "cycle_tables"

module Quaack
  module Enclave
    module Steps
      # What became of one stored rewrite, for ReportPayload's rewrites
      # field (DESIGN.md report and negative-result): the one step that took it out of
      # the run, or that it was ranked.
      #
      #   context = RewriteFate.context(store)
      #   RewriteFate.call(store, "rewrite_2", context)
      #   # => { "fate" => "rewrite_test_disproved", "scenario" => "s3", "rule" => "multiset",
      #   #      "round" => nil, "after" => nil }
      #
      # A rewrite has several measured labels and one fate. The first of
      # these that holds is its fate:
      #
      #   ranked                   selection ranked one of its labels
      #   same_plans               plan-pruning found it plans as the original
      #                            does, so it was never tested
      #   rewrite_test_disproved          a rewrite-test scenario got different results;
      #                            with the scenario and the rule
      #   rewrite_test_untested           rewrite-test couldn't build scenarios for the
      #                            query (rewrite_tested_<n> says refused),
      #                            so the rewrite was never tested; with the
      #                            refusal's rule, and for fk_cycle the
      #                            cycle's tables
      #   rewrite_test_failed             a rewrite-test scenario ended without comparing
      #                            results (the original's order can't be
      #                            checked, or a statement failed in arena);
      #                            with the scenario and the rule
      #   counterexamples_disproved         a counterexample-compare round got different results; with
      #                            the round and the rule
      #   counterexamples_failed            a counterexample-compare round ended without comparing
      #                            results; with the round and the rule
      #   production_mismatch      result-comparison got different results on production
      #                            data; with the first rule of MISMATCHES
      #                            among its failing verdicts
      #   production_timed_out     result-comparison dropped it for a timeout, and no
      #                            literal set's results differed
      #   production_not_compared  result-comparison dropped it without comparing (rule
      #                            unsupported_order), or selection excluded it as
      #                            result_mismatch and result-comparison's entry doesn't
      #                            say why
      #   below_top_three          a label beat the original and fell
      #                            outside selection's top three
      #   footprint_tie            a label beat the original and lost
      #                            minimax's footprint tiebreak
      #   not_better               it was measured and minimax found no
      #                            label better than the original
      #   measurement_timed_out    every one of its runs in candidate-runs timed out
      #   unfinished               the run took it no further; after is the
      #                            last stage it finished: nil (only
      #                            stored), rewrite-test, counterexamples, or measurement
      #
      # A plan-pruning prune (rewrite_pruned_<n> says discarded) comes before the rewrite-test fates because
      # rewrite-test stores a pruned rewrite as not passed, with rule discarded, without testing it. The rewrite-test
      # and counterexamples fates come before the measured ones because a rewrite either step stopped is never
      # measured. Among the measured ones, result-comparison's come first: result-comparison drops the whole rewrite,
      # so none of its labels counts.
      #
      # Trust boundary. Everything this returns is one of this module's own
      # constants: a fate from FATES, a rule from MISMATCHES, FAILURES,
      # REFUSALS, or PRODUCTION_FAILURES, a scenario from Scenarios::NAMES,
      # a round from ROUNDS, and an after from AFTER. A stored value that
      # isn't on its list goes out as nil, never as it is. The one
      # exception is an fk_cycle's cycle: table names, which are schema,
      # each the schema_subset entry's own (the catalog's relations). A
      # cycle with any other value goes out as nil.
      module RewriteFate
        FATES = %w[ranked same_plans rewrite_test_disproved rewrite_test_untested rewrite_test_failed
                   counterexamples_disproved counterexamples_failed production_mismatch production_timed_out
                   production_not_compared below_top_three footprint_tie not_better measurement_timed_out
                   unfinished].freeze

        # The rules that say two results differed, in rewrite-test, counterexamples, and result-comparison.
        MISMATCHES = ResultComparator::MISMATCHES.map(&:to_s).freeze

        # The rules that end a rewrite-test scenario or a counterexample-compare round with nothing
        # compared: the comparison's refusal, and ArenaRunner's and
        # ArenaFixture's failures.
        FAILURES = %w[unsupported_order statement_unparsable statement_not_allowed begin_failed
                      already_in_transaction connection_unusable fixture_load_failed reverse_load_failed
                      rotated_load_failed
                      insert_failed query_failed transaction_ended rollback_failed statement_timeout
                      statement_canceled].freeze

        # Scenarios::Error's rules: why rewrite-test couldn't build scenarios.
        REFUSALS = %w[fk_cycle complex_check unsatisfiable_check expression_unique_index unsupported_type
                      domain_check exclusion_constraint].freeze

        # result-comparison's failing rules that compare nothing.
        PRODUCTION_FAILURES = %w[timed_out unsupported_order].freeze

        SCENARIOS = Scenarios::NAMES.map(&:to_s).freeze
        ROUNDS = [1, 2, 3].freeze
        AFTER = %w[rewrite-test counterexamples measurement].freeze

        # selection's reasons for a label that result-comparison didn't drop, strongest first.
        EXCLUDED = %w[below_top_three footprint_tie not_better].freeze

        BLANK = { "fate" => nil, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil,
                  "cycle" => nil }.freeze

        # What every rewrite's fate reads from candidate-runs on, read once.
        # tables is the schema subset's relations (schema-dump), as "schema.name".
        Context = Data.define(:top, :excluded, :measured, :timed_out, :verdicts, :tables)

        module_function

        # selection, if given, stands in for the stored entry, for selection
        # itself, which records the fates before it writes it.
        def context(store, selection: store.read("selection"))
          runs = store.read("candidate_runs")
          compared = store.read("result_comparison") if store.entry?("result_comparison")
          Context.new(top: selection["top"].map { it["label"] }, excluded: selection["excluded"],
                      measured: runs["candidates"].keys, timed_out: runs["timed_out"],
                      verdicts: compared ? compared["verdicts"] : {}, tables: CycleTables.tables(store))
        end

        def call(store, rewrite, context)
          steps = steps(store, rewrite.delete_prefix("rewrite_"))
          ranked(rewrite, context) || early(steps, context) || production(rewrite, context) ||
            measured(rewrite, context) || unfinished(rewrite, steps, context)
        end

        # The rewrite's own plan-pruning to counterexamples entries, each nil if it isn't stored.
        def steps(store, number)
          %w[pruned tested round survived].to_h do |step|
            entry = "rewrite_#{step}_#{number}"
            [step, (store.read(entry) if store.entry?(entry))]
          end
        end

        def fate(name, **details) = BLANK.merge("fate" => FATES.find { it == name }, **details.transform_keys(&:to_s))

        # value if it's one of list, as the list's own object, or nil.
        def known(list, value) = list.find { it == value }

        def mine?(rewrite, label) = label.is_a?(String) && label.split(":").first == rewrite

        def ranked(rewrite, context)
          fate("ranked") if context.top.any? { mine?(rewrite, it) }
        end

        # plan-pruning, rewrite-test, and counterexamples, in that order.
        def early(steps, context)
          tested = steps["tested"]
          return fate("same_plans") if steps.dig("pruned", "discarded") == true
          return unless tested
          return rewrite_test(tested, context) unless tested["passed"]

          counterexamples(steps["round"] || {}) if steps.dig("survived", "survived") == false
        end

        def rewrite_test(tested, context)
          return untested(tested, context) if tested["refused"] == true

          scenario = known(SCENARIOS, tested["scenario"])
          mismatch = known(MISMATCHES, tested["rule"])
          return fate("rewrite_test_disproved", scenario:, rule: mismatch) if mismatch

          fate("rewrite_test_failed", scenario:, rule: known(FAILURES, tested["rule"]))
        end

        def untested(tested, context)
          rule = known(REFUSALS, tested["rule"])
          cycle = CycleTables.check(tested["cycle"], context.tables) if rule == "fk_cycle"
          fate("rewrite_test_untested", rule:, cycle:)
        end

        # A round entry with no rule was written before rounds kept theirs
        # (or isn't there at all): then, survived false only ever followed a
        # round that didn't match, so it reads as a disproof.
        def counterexamples(round)
          number = known(ROUNDS, round["round"])
          return fate("counterexamples_disproved", round: number) if round["rule"].nil?

          mismatch = known(MISMATCHES, round["rule"])
          return fate("counterexamples_disproved", round: number, rule: mismatch) if mismatch

          fate("counterexamples_failed", round: number, rule: known(FAILURES, round["rule"]))
        end

        # result-comparison's fates, from the rewrite's failing verdicts.
        def production(rewrite, context)
          failing = failing_rules(context.verdicts[rewrite])
          mismatch = MISMATCHES.find { failing.include?(it) }
          return fate("production_mismatch", rule: mismatch) if mismatch
          return fate("production_timed_out") if failing.include?("timed_out")
          return if failing.empty? && !reasons(rewrite, context).include?("result_mismatch")

          fate("production_not_compared", rule: PRODUCTION_FAILURES.find { failing.include?(it) })
        end

        def failing_rules(verdicts)
          return [] unless verdicts.is_a?(Hash)

          verdicts.values.filter_map { it["rule"] if it.is_a?(Hash) && it["result"] == "fail" }
        end

        # selection's reasons for the rewrite's excluded labels.
        def reasons(rewrite, context) = context.excluded.filter_map { |label, reason| reason if mine?(rewrite, label) }

        def measured(rewrite, context)
          reason = EXCLUDED.find { reasons(rewrite, context).include?(it) }
          return fate(reason) if reason
          return if context.measured.include?(rewrite)

          fate("measurement_timed_out") if context.timed_out.any? { mine?(rewrite, it) }
        end

        def unfinished(rewrite, steps, context)
          after = if context.measured.include?(rewrite) then "measurement"
                  elsif steps.dig("survived", "survived") == true then "counterexamples"
                  elsif steps.dig("tested", "passed") == true then "rewrite-test"
                  end
          fate("unfinished", after: known(AFTER, after))
        end
      end
    end
  end
end
