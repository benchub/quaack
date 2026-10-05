# frozen_string_literal: true

require_relative "burndown"

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

      def generated_record(stage, search, source, generated)
        count = generated.fetch(source)
        [stage, search, { in: 0, added: { source => count }, out: count }]
      end
    end
  end
end
