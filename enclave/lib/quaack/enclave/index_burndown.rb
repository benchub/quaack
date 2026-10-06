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

      # Records one index-rank run for search, in place of any earlier one
      # (Burndown.record_replacing), since a rewrite's search is ranked in
      # plan-pruning and again after rewrite-index-ideas. ranked is [report,
      # ranking]: the SingleCandidateTest report of the candidates index-rank
      # tested again, and IndexRanking's Ranking. in is those candidates,
      # added is the combinations it measured, and out is the top singles
      # and the combination, if any. Each plan either made is a
      # hypothetical_explains.
      #
      # Once llm-index-ideas has run for the search (index_generated_<search>),
      # if none of its candidates fell short in entry, the search's entry
      # (Refinement.shortfalls), the driver skips llm-index-refine, so this
      # also records why: no_ideas_tested, or nothing_fell_short.
      def record_rank(store, search, entry, ranked)
        report, ranking = ranked
        records = [["index-rank", search, rank_counts(report, ranking)]]
        records << ["llm-index-refine", search, skipped(entry)] if skipped?(store, search, entry)
        Burndown.record_replacing(
          store, records, totals: { hypothetical_explains: Burndown.tested_totals(report)[:hypothetical_explains] +
                                                           ranking.tally.explains }
        )
      end

      # The candidates tested again that weren't ranked count as index-test
      # drops them, then the ranked ones below the top three, then the
      # combinations not kept.
      def rank_counts(report, ranking)
        tested = Burndown.single_candidate_test_record(report, search: :original).last
        top = ranking.top.size
        kept = ranking.combination ? 1 : 0
        dropped = tested[:dropped].merge(rank_drops(ranking.tally, top, kept))
        { in: tested[:in], added: { combinations: ranking.tally.combinations },
          dropped: dropped.reject { |_, n| n.zero? }, out: top + kept }
      end

      def rank_drops(tally, top, kept)
        { below_top_three: tally.ranked - top, combination_unused_index: tally.unused_index,
          combination_not_chosen: tally.combinations - tally.unused_index - kept }
      end

      def skipped?(store, search, entry)
        store.entry?("index_generated_#{search}") && Refinement.shortfalls(entry).none?
      end

      def skipped(entry)
        why = Refinement.first_round(entry).empty? ? :no_ideas_tested : :nothing_fell_short
        { in: 0, out: 0, extra: { why => 1 } }
      end

      def generated_record(stage, search, source, generated)
        count = generated.fetch(source)
        [stage, search, { in: 0, added: { source => count }, out: count }]
      end
    end
  end
end
