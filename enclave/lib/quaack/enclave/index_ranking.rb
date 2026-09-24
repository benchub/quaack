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

        # The DDL can hold a partial index's predicate, so it's left out.
        def inspect
          "#<data #{self.class} indexes=#{ddl.size}, size=#{size}, costs=#{costs}, used=#{used}, " \
            "partial=#{partial}, ddl=<redacted>>"
        end

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      Cost = Data.define(:before, :after) do
        def reduction = after == before ? 0.0 : 1 - (after / before)
      end

      # The most indexes in a combination, and the most single entries kept.
      MAX_INDEXES = 3
      TOP = 3

      module_function

      def rank(connection, query:, literal_sets:, baseline:, results:)
        unless [baseline, *results.reject(&:refusal)].all? { |r| r.plans.keys.to_set == literal_sets.keys.to_set }
          raise ArgumentError, "literal sets must match the baseline's and every result's"
        end

        pool = results.select(&:used?).map { |r| single(r, baseline) }
        singles = ranked(pool)
        combination = combine(connection, query, literal_sets, baseline, pool, singles.first) if pool.size > 1
        Ranking.new(top: singles.first(TOP).freeze, combination:)
      end

      def ranked(entries) = entries.sort_by { |e| [-e.worst_reduction, e.size, e.ddl] }

      def single(result, baseline)
        entry([result.candidate], result.size, result.plans, result.plans.transform_values { |p| [p.used] }, baseline)
      end

      def entry(candidates, size, plans, used, baseline)
        Entry.new(candidates:, ddl: candidates.map(&:to_ddl), size:, costs: costs(plans, baseline), used:,
                  canonical_plans: plans.transform_values(&:canonical_plan), partial: candidates.any?(&:predicate))
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

        entry(candidates, measured.sizes.sum, measured.plans, used, baseline)
      end
    end
  end
end
