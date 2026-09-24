# frozen_string_literal: true

require_relative "single_candidate_test"

module Quaack
  module Enclave
    # README 5a-7 (stub).
    module IndexRanking
      Ranking = Data.define(:top, :combination)

      Entry = Data.define(:candidates, :ddl, :size, :costs, :used, :canonical_plans, :partial) do
        def reductions = costs.transform_values(&:reduction)

        def worst_reduction = reductions.values.min
      end

      Cost = Data.define(:before, :after) do
        def reduction = 1 - (after / before)
      end

      # The most indexes in a combination, and the most single entries kept.
      MAX_INDEXES = 3
      TOP = 3

      module_function

      def rank(connection, query:, literal_sets:, baseline:, results:)
        pool = results.select(&:used?).map { |r| single(r, baseline) }
        singles = ranked(pool)
        combination = combine(connection, query, literal_sets, baseline, pool, singles.first) if pool.size > 1
        Ranking.new(top: singles.first(TOP).freeze, combination:)
      end

      def ranked(entries) = entries.sort_by { |e| [-e.worst_reduction, e.size, e.ddl] }

      def single(result, baseline)
        Entry.new(candidates: [result.candidate], ddl: [result.candidate.to_ddl], size: result.size,
                  costs: costs(result.plans, baseline), used: result.plans.transform_values { |p| [p.used] },
                  canonical_plans: result.plans.transform_values(&:canonical_plan), partial: false)
      end

      def costs(plans, baseline)
        plans.to_h { |set, plan| [set, Cost.new(before: baseline.plans[set].total_cost, after: plan.total_cost)] }
      end

      # Greedy: add the candidate from pool that lowers the worst case most,
      # while one does, up to MAX_INDEXES.
      def combine(connection, query, literal_sets, baseline, pool, best)
        SingleCandidateTest.session(connection, query:, literal_sets:) do |session|
          current = best
          while current.candidates.size < MAX_INDEXES
            tries = pool.reject { |e| current.candidates.include?(e.candidates.first) }
                        .filter_map { |e| combined(session, current.candidates + e.candidates, baseline) }
            better = ranked(tries).first
            break unless better && better.worst_reduction > current.worst_reduction

            current = better
          end
          current.candidates.size > 1 ? current : nil
        end
      end

      # The Entry for these candidates' indexes together, or nil if HypoPG
      # refused one or some index goes unused for every literal set.
      def combined(session, candidates, baseline)
        measured = session.measure(candidates)
        return nil if measured.refusal

        used = measured.plans.transform_values(&:used)
        return nil unless candidates.each_index.all? { |i| used.each_value.any? { |u| u[i] } }

        Entry.new(candidates:, ddl: candidates.map(&:to_ddl), size: measured.sizes.sum,
                  costs: costs(measured.plans, baseline), used:,
                  canonical_plans: measured.plans.transform_values(&:canonical_plan), partial: false)
      end
    end
  end
end
