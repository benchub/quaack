# frozen_string_literal: true

require_relative "single_candidate_test"

module Quaack
  module Enclave
    # DESIGN.md 5a-7: rank the index candidates that 5a-4 tested, and combine
    # them greedily. Step 8 ranks a rewrite's mechanical candidates the same
    # way, and step 11 calls it for a rewrite, with the rewrite's query.
    #
    #   report = SingleCandidateTest.run(connection, query:, literal_sets:, candidates:)
    #   IndexRanking.rank(connection, query:, literal_sets:,
    #                     baseline: report.baseline, results: report.results + llm_report.results)
    #   # => Ranking(top: [Entry, Entry, Entry], combination: Entry or nil)
    #
    # connection, query, and literal_sets are as SingleCandidateTest.run
    # takes them. baseline is a 5a-4 Baseline, and results are 5a-4 Results
    # from any generator and any number of runs, all for this query and
    # these literal sets. literal_sets must name the same sets as the
    # baseline and every result that wasn't refused, or rank raises
    # ArgumentError.
    #
    # A candidate's reduction for a literal set is 1 - after / before, where
    # before is the baseline's total cost and after is the cost with the
    # index. It's negative when the index makes that literal worse, and 0
    # when both costs are the same, even 0. Its worst reduction is the
    # smallest across the literal sets. The ranking puts the highest worst
    # reduction first, breaks a tie on the next-worst reduction, and so on
    # up the sets, then by size, smallest first, and breaks any tie left by
    # DDL, so the same results rank the same way in any order.
    #
    # Only candidates the planner used for some literal set are ranked. As
    # DESIGN.md 5a-4 says, one it never used is discarded here, and so is one
    # HypoPG refused. Their Results stay with the caller for 5a-5. top holds
    # the first three.
    #
    # The combination starts from the best single candidate. Each round
    # measures it together with each ranked candidate it doesn't hold yet,
    # with all of their hypothetical indexes present at once. Of those whose
    # plans use every one of their indexes for some literal set, and that
    # lower some literal set's cost without raising any (DESIGN.md 5a-7), the
    # best by the same ranking replaces it. Rounds stop at three
    # indexes or when nothing is better. combination is nil if no pair beat
    # the best single candidate, and otherwise holds its candidates in the
    # order they were added. The measuring runs in a SingleCandidateTest
    # Session, so it has 5a-4's transaction, settings, hidden-index check,
    # fresh prepares, notice handling, and cleanup. It happens only when
    # there are at least two ranked candidates. Its costs are compared with
    # the caller's baseline.
    #
    # Errors: SingleCandidateTest::Error for literals and for anything from
    # Postgres, with a rule and SQLSTATE and nothing from Postgres, since a
    # Postgres message can quote a literal.
    #
    # Which fields are which, for whoever sends these through egress later:
    # - Shape-class, which could leave: Entry#size, #costs, #used, #partial,
    #   #reductions, and #worst_reduction.
    # - Enclave-only: Entry#canonical_plans (see 20260923-28), and
    #   Entry#candidates and #ddl. A partial index's predicate, in its DDL,
    #   holds a literal from a low-cardinality column, which may leave only
    #   under DESIGN.md 3f's rule, so inspect and to_s leave the DDL out.
    # Nothing here goes through egress yet.
    module IndexRanking
      # top has up to three single-index Entries, best first. combination
      # is an Entry with two or three indexes, or nil.
      Ranking = Data.define(:top, :combination)

      # One index, or a combination of them. candidates are the
      # IndexCandidates, and ddl has each one's to_ddl, in the same order.
      # size is the sum of their hypopg_relation_size, in bytes. costs,
      # used, and canonical_plans map each literal set's name to its Cost,
      # to one boolean per index saying whether the plan uses it, and to
      # its CanonicalPlan. partial is true if any index has a predicate:
      # DESIGN.md 5a-5 says such an index works only if the predicate's literal
      # is a constant in the application's SQL. plans maps each literal set
      # to its 5a-4 Plan, raw and enclave-only.
      Entry = Data.define(:candidates, :ddl, :size, :costs, :used, :canonical_plans, :plans, :partial) do
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

      # One literal set's total cost before (the baseline) and after (with
      # the entry's indexes).
      Cost = Data.define(:before, :after) do
        def reduction = after == before ? 0.0 : 1 - (after / before)
      end

      # The most indexes in a combination, and the most single entries kept.
      MAX_INDEXES = 3
      TOP = 3

      module_function

      def rank(connection, query:, literal_sets:, baseline:, results:, types: nil) # rubocop:disable Metrics/ParameterLists
        check(literal_sets, baseline, results)
        pool = results.select(&:used?).map { |r| single(r, baseline) }
        singles = ranked(pool)
        if pool.size > 1
          combination = SingleCandidateTest.session(connection, query:, literal_sets:, types:) do |session|
            combine(session, baseline, pool, singles.first)
          end
        end
        Ranking.new(top: singles.first(TOP).freeze, combination:)
      end

      def check(literal_sets, baseline, results)
        raise SingleCandidateTest::Error, :bad_literal unless SingleCandidateTest.literal_sets?(literal_sets)
        return if [baseline, *results.reject(&:refusal)].all? { |r| r.plans.keys.to_set == literal_sets.keys.to_set }

        raise ArgumentError, "literal sets must match the baseline's and every result's"
      end

      def ranked(entries) = entries.sort_by { |e| [e.reductions.values.sort.map(&:-@), e.size, e.ddl] }

      def single(result, baseline)
        entry([result.candidate], result.size, result.plans, result.plans.transform_values { |p| [p.used] }, baseline)
      end

      def entry(candidates, size, plans, used, baseline)
        Entry.new(candidates: candidates.freeze, ddl: candidates.map(&:to_ddl).freeze, size:,
                  costs: costs(plans, baseline).freeze, used: used.transform_values { |u| u.dup.freeze }.freeze,
                  canonical_plans: plans.transform_values(&:canonical_plan).freeze, plans: plans.freeze,
                  partial: candidates.any?(&:predicate))
      end

      def costs(plans, baseline)
        plans.to_h { |set, plan| [set, Cost.new(before: baseline.plans[set].total_cost, after: plan.total_cost)] }
      end

      # pool holds an Entry for each ranked candidate, and best is the first
      # of them by the ranking. A candidate is never measured with itself,
      # since one of two identical indexes always goes unused.
      def combine(session, baseline, pool, best)
        current = best
        while current.candidates.size < MAX_INDEXES
          better = ranked(additions(session, baseline, pool, current).select { |e| lower?(e, current) }).first
          break unless better

          current = better
        end
        current.candidates.size > 1 ? current : nil
      end

      # DESIGN.md 5a-7: an addition lowers the cost if it lowers some literal
      # set's cost and raises none.
      def lower?(entry, current)
        pairs = entry.costs.map { |set, cost| [cost.after, current.costs[set].after] }
        pairs.none? { |after, was| after > was } && pairs.any? { |after, was| after < was }
      end

      # current with each candidate in pool it doesn't hold yet.
      def additions(session, baseline, pool, current)
        pool.reject { |e| current.candidates.include?(e.candidates.first) }
            .filter_map { |e| combined(session, current.candidates + e.candidates, baseline) }
      end

      # The Entry for these candidates' indexes together, or nil if the
      # plans leave some index unused for every literal set. A measurement
      # HypoPG refused has no plans, so it's nil too.
      def combined(session, candidates, baseline)
        measured = session.measure(candidates)
        used = measured.plans.transform_values(&:used)
        return nil unless candidates.each_index.all? { |i| used.each_value.any? { |u| u[i] } }

        entry(candidates, measured.sizes.sum, measured.plans, used, baseline)
      end
    end
  end
end
