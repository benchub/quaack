# frozen_string_literal: true

require_relative "burndown"
require_relative "refinement"

module Quaack
  module Enclave
    # DESIGN.md's burndown's index stages, as Burndown records, for one
    # search: the original query's, or a rewrite's (plan-pruning and
    # rewrite-index-ideas). Only counts and QUAACK's own names.
    module IndexBurndown
      module_function

      # Records index-search's burndown for search, once (see
      # Burndown.record_once): index-from-query and index-from-plan, each
      # adding its generator's candidates (generated is { generator_one:,
      # generator_two: } counts), then index-dedupe on all of them, and
      # index-test on the Dedupe's proposals. test is [report, set_aside]:
      # index-test's SingleCandidateTest report, whose EXPLAINs are the total
      # hypothetical_explains, and the unused candidates it held for
      # index-build.
      def record_search(store, search, generated, dedupe:, test:)
        report, set_aside = test
        Burndown.record_once(
          store, [generated_record("index-from-query", search, :generator_one, generated),
                  generated_record("index-from-plan", search, :generator_two, generated),
                  Burndown.dedupe_record(dedupe, search:),
                  Burndown.single_candidate_test_record(report, search:, set_aside:)],
          totals: Burndown.tested_totals(report)
        )
      end

      # Records one index-test call's LLM round for search: llm-index-ideas,
      # or llm-index-refine for round "refinement" (see
      # Burndown.record_llm_round). since is the stored Dedupe's counts from
      # before this call's filtering, so only its own count, and result is
      # GeneratorThree's. Each DDL GeneratorThree dropped before it reached
      # the Dedupe counts as refused, by its rule. For llm-index-refine, entry
      # is the search's entry from before the round, and the record keeps how
      # many first-round candidates fell short (Refinement.shortfalls).
      def record_round(store, search, round, entry:, tested:)
        since, dedupe, result, report = tested
        Burndown.record_llm_round(
          store, stage: round ? "llm-index-refine" : "llm-index-ideas", search:, dedupe:, since:, report:,
                 refused: refused(result, since, dedupe),
                 extra: round ? { fell_short: Refinement.shortfalls(entry).compact.size } : {}
        )
      end

      # GeneratorThree's dropped DDL by rule, less what the Dedupe dropped
      # since, which leaves the ones refused before it. Every rule is one of
      # the enclave's constants (see GeneratorThree).
      def refused(result, since, dedupe)
        deduped = Burndown.dedupe_counts(dedupe)[:dropped]
        dropped_rules(result).to_h { |rule, n| [rule, n - deduped.fetch(rule, 0) + since[:dropped].fetch(rule, 0)] }
                             .reject { |_, n| n.zero? }
      end

      def dropped_rules(result) = result.outcomes.select { it.status == :dropped }.map { it.rule.to_sym }.tally

      def generated_record(stage, search, source, generated)
        count = generated.fetch(source)
        [stage, search, { in: 0, added: { source => count }, out: count }]
      end
    end
  end
end
