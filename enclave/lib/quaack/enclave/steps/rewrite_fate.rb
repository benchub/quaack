# frozen_string_literal: true

require_relative "../result_comparator"
require_relative "../scenarios"

module Quaack
  module Enclave
    module Steps
      # What became of one stored rewrite, for ReportPayload's rewrites
      # field (DESIGN.md step 15 and 15a): the one step that took it out of
      # the run, or that it was ranked.
      #
      #   context = RewriteFate.context(store)
      #   RewriteFate.call(store, "rewrite_2", context)
      #   # => { "fate" => "step9_disproved", "scenario" => "s3", "rule" => "multiset",
      #   #      "round" => nil, "after" => nil }
      #
      # A rewrite has several measured labels and one fate. The first of
      # these that holds is its fate:
      #
      #   ranked                   14d ranked one of its labels
      #   same_plans               step 8 found it plans as the original
      #                            does, so it was never tested
      #   step9_disproved          a step 9 scenario got different results;
      #                            with the scenario and the rule
      #   step9_untested           step 9 couldn't build scenarios for the
      #                            query (rewrite_tested_<n> says refused),
      #                            so the rewrite was never tested; with the
      #                            refusal's rule, and for fk_cycle the
      #                            cycle's tables
      #   step9_failed             a step 9 scenario ended without comparing
      #                            results (the original's order can't be
      #                            checked, or a statement failed in arena);
      #                            with the scenario and the rule
      #   step10_disproved         a 10b round got different results; with
      #                            the round and the rule
      #   step10_failed            a 10b round ended without comparing
      #                            results; with the round and the rule
      #   production_mismatch      14c got different results on production
      #                            data; with the first rule of MISMATCHES
      #                            among its failing verdicts
      #   production_timed_out     14c dropped it for a timeout, and no
      #                            literal set's results differed
      #   production_not_compared  14c dropped it without comparing (rule
      #                            unsupported_order), or 14d excluded it as
      #                            result_mismatch and 14c's entry doesn't
      #                            say why
      #   below_top_three          a label beat the original and fell
      #                            outside 14d's top three
      #   footprint_tie            a label beat the original and lost
      #                            minimax's footprint tiebreak
      #   not_better               it was measured and minimax found no
      #                            label better than the original
      #   measurement_timed_out    every one of its step 14 runs timed out
      #   unfinished               the run took it no further; after is the
      #                            last stage it finished: nil (only
      #                            stored), step9, step10, or measurement
      #
      # A step 8 prune (rewrite_pruned_<n> says discarded) comes before the
      # step 9 fates because rewrite-test stores a pruned rewrite as not
      # passed, with rule discarded, without testing it. The step 9 and 10 fates come before the measured ones
      # because a rewrite either step stopped is never measured. Among the
      # measured ones, 14c's come first: 14c drops the whole rewrite, so
      # none of its labels counts.
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
        FATES = %w[ranked same_plans step9_disproved step9_untested step9_failed step10_disproved step10_failed
                   production_mismatch production_timed_out production_not_compared below_top_three
                   footprint_tie not_better measurement_timed_out unfinished].freeze

        # The rules that say two results differed, in steps 9, 10, and 14c.
        MISMATCHES = ResultComparator::MISMATCHES.map(&:to_s).freeze

        # The rules that end a step 9 scenario or a 10b round with nothing
        # compared: the comparison's refusal, and ArenaRunner's and
        # ArenaFixture's failures.
        FAILURES = %w[unsupported_order statement_unparsable statement_not_allowed begin_failed
                      already_in_transaction connection_unusable fixture_load_failed reverse_load_failed
                      insert_failed query_failed transaction_ended rollback_failed statement_timeout
                      statement_canceled].freeze

        # Scenarios::Error's rules: why step 9 couldn't build scenarios.
        REFUSALS = %w[fk_cycle complex_check unsatisfiable_check expression_unique_index unsupported_type
                      domain_check].freeze

        # 14c's failing rules that compare nothing.
        PRODUCTION_FAILURES = %w[timed_out unsupported_order].freeze

        SCENARIOS = Scenarios::NAMES.map(&:to_s).freeze
        ROUNDS = [1, 2, 3].freeze
        AFTER = %w[step9 step10 measurement].freeze

        # 14d's reasons for a label that 14c didn't drop, strongest first.
        EXCLUDED = %w[below_top_three footprint_tie not_better].freeze

        BLANK = { "fate" => nil, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil,
                  "cycle" => nil }.freeze

        # A cycle names at least two tables, and its first table again.
        MIN_CYCLE = 3

        # What every rewrite's fate reads from steps 14 on, read once.
        # tables is the schema subset's relations (3b), as "schema.name".
        Context = Data.define(:top, :excluded, :measured, :timed_out, :verdicts, :tables)

        module_function

        def context(store)
          selection = store.read("selection")
          runs = store.read("candidate_runs")
          compared = store.read("result_comparison") if store.entry?("result_comparison")
          Context.new(top: selection["top"].map { it["label"] }, excluded: selection["excluded"],
                      measured: runs["candidates"].keys, timed_out: runs["timed_out"],
                      verdicts: compared ? compared["verdicts"] : {}, tables: tables(store))
        end

        def tables(store)
          return [] unless store.entry?("schema_subset")

          store.read("schema_subset")["tables"].map { |schema, name| "#{schema}.#{name}" }.uniq.freeze
        end

        def call(store, rewrite, context)
          steps = steps(store, rewrite.delete_prefix("rewrite_"))
          ranked(rewrite, context) || early(steps, context) || production(rewrite, context) ||
            measured(rewrite, context) || unfinished(rewrite, steps, context)
        end

        # The rewrite's own step 8 to 10 entries, each nil if it isn't stored.
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

        # Steps 8, 9, and 10, in that order.
        def early(steps, context)
          tested = steps["tested"]
          return fate("same_plans") if steps.dig("pruned", "discarded") == true
          return unless tested
          return step9(tested, context) unless tested["passed"]

          step10(steps["round"] || {}) if steps.dig("survived", "survived") == false
        end

        def step9(tested, context)
          return untested(tested, context) if tested["refused"] == true

          scenario = known(SCENARIOS, tested["scenario"])
          mismatch = known(MISMATCHES, tested["rule"])
          return fate("step9_disproved", scenario:, rule: mismatch) if mismatch

          fate("step9_failed", scenario:, rule: known(FAILURES, tested["rule"]))
        end

        def untested(tested, context)
          rule = known(REFUSALS, tested["rule"])
          fate("step9_untested", rule:, cycle: (cycle(tested["cycle"], context) if rule == "fk_cycle"))
        end

        # The stored cycle's tables, each as the schema subset's own
        # "schema.name", or nil unless every one is a relation the subset
        # holds and the cycle closes.
        def cycle(stored, context)
          return unless stored.is_a?(Array) && stored.size >= MIN_CYCLE && stored.first == stored.last
          return unless stored.all? { it.is_a?(Array) && it.size == 2 && it.all?(String) }

          names = stored.map { |schema, name| known(context.tables, "#{schema}.#{name}") }
          names unless names.include?(nil)
        end

        # A round entry with no rule was written before rounds kept theirs
        # (or isn't there at all): then, survived false only ever followed a
        # round that didn't match, so it reads as a disproof.
        def step10(round)
          number = known(ROUNDS, round["round"])
          return fate("step10_disproved", round: number) if round["rule"].nil?

          mismatch = known(MISMATCHES, round["rule"])
          return fate("step10_disproved", round: number, rule: mismatch) if mismatch

          fate("step10_failed", round: number, rule: known(FAILURES, round["rule"]))
        end

        # 14c's fates, from the rewrite's failing verdicts.
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

        # 14d's reasons for the rewrite's excluded labels.
        def reasons(rewrite, context) = context.excluded.filter_map { |label, reason| reason if mine?(rewrite, label) }

        def measured(rewrite, context)
          reason = EXCLUDED.find { reasons(rewrite, context).include?(it) }
          return fate(reason) if reason
          return if context.measured.include?(rewrite)

          fate("measurement_timed_out") if context.timed_out.any? { mine?(rewrite, it) }
        end

        def unfinished(rewrite, steps, context)
          after = if context.measured.include?(rewrite) then "measurement"
                  elsif steps.dig("survived", "survived") == true then "step10"
                  elsif steps.dig("tested", "passed") == true then "step9"
                  end
          fate("unfinished", after: known(AFTER, after))
        end
      end
    end
  end
end
