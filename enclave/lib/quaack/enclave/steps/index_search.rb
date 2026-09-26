# frozen_string_literal: true

require "pg_query"
require_relative "../dedupe"
require_relative "../generator_one"
require_relative "../generator_two"
require_relative "../index_store"
require_relative "../literal_set"
require_relative "../pii_classification"
require_relative "../plan_gate"
require_relative "../planner_statistics"
require_relative "../redaction"
require_relative "../run_server"
require_relative "../single_candidate_test"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-search --run <run ID> [--search original]` (README 5,
      # 5a-1 to 5a-4): the mechanical half of the index search, on the
      # racetrack that `quaacks racetrack-setup` set up.
      #
      # It refuses an unknown search (index_search_unknown_search; only
      # original exists until rewrites do) and a run with no racetrack_setup
      # marker (index_search_no_racetrack_setup), before connecting. Then,
      # on one racetrack connection: the plan gate on anchored_query; 5a-1
      # on the parse of anchored_query and 5a-2 on the step 1 plan, each
      # filtered by one 5a-3 Dedupe as soon as it's produced; and 5a-4 on
      # the survivors, for each 3e literal set.
      #
      # It writes one entry, index_search_<search>, only when all of that
      # succeeds:
      #   "dedupe"   => the Dedupe, as IndexStore saves it, so 5a-5's
      #                 index-test can go on with the same search
      #   "baseline" => { set name => a plan, as below, with no hypothetical
      #                 index }
      #   "results"  => one per tested candidate, in test order (the
      #                 Dedupe's proposals): { "candidate" (as IndexStore
      #                 saves it, sources merged), "partial_constant_only"
      #                 (README 5a-5's tag: true for a partial index, which
      #                 works only when the predicate's literal is a constant
      #                 in the application's SQL), "size", "refusal" (nil or
      #                 { "rule", "sqlstate" }), "plans" => { set name =>
      #                 { "used", "total_cost", "plan" } } }
      # "plan" is the EXPLAIN redacted through 3g (Redaction.plan) against
      # that set's own literals, so it holds placeholders, never a literal.
      # Raw plans aren't saved.
      #
      # The racetrack is production data and candidates can hold literals,
      # so nothing here goes out. Its only line is DONE, and a failure names
      # only its rule.
      module IndexSearch
        OPTIONS = { "search" => :value }.freeze
        SEARCHES = %w[original].freeze

        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        module_function

        def call(store:, options:, **)
          search = check(store, options.fetch("search", "original"))
          sql = store.read("anchored_query")
          connection = Enclave::RunServer.connect(store, :racetrack)
          PlanGate.check(store:, connection:, sql:)
          store.write("index_search_#{search}", original_entry(store, connection, sql))
          []
        ensure
          connection&.close
        end

        # 5a-1 to 5a-4 for the original, on the step 1 plan.
        def original_entry(store, connection, sql)
          dedupe, candidates = mechanical(store, sql, plan: store.read("plan"), analyzed: true)
          maps = LiteralSet.load(store).sets
          entry(dedupe, SingleCandidateTest.run(connection, query: sql, literal_sets: values(maps), candidates:), maps)
        end

        # README step 8: the same search for one rewrite candidate, sql, as
        # the inbound check accepted it, with the original's $n. 5a-1 runs on
        # its parse, and 5a-2 on its plain EXPLAIN on the racetrack with the
        # slow literals (analyzed: false, since a rewrite has no production
        # EXPLAIN ANALYZE). Its Dedupe is its own, so 5a-3 compares only
        # against existing indexes and its own proposals. 5a-4 runs the
        # rewrite. It returns the entry, in the index_search_<search> form,
        # for the caller to store. There's no plan gate: the rewrite has no
        # production plan to compare with.
        def rewrite_entry(store, connection, sql)
          maps = LiteralSet.load(store).sets
          literal_sets = values(maps)
          dedupe, candidates = mechanical(store, sql, plan: slow_plan(connection, sql, literal_sets), analyzed: false)
          entry(dedupe, SingleCandidateTest.run(connection, query: sql, literal_sets:, candidates:), maps)
        end

        # The query's plain EXPLAIN with the slow literals.
        def slow_plan(connection, sql, literal_sets)
          report = SingleCandidateTest.run(connection, query: sql, literal_sets: literal_sets.slice("slow"),
                                                       candidates: [])
          report.baseline.plans.fetch("slow").raw_plan
        end

        # The refusals made before connecting. Returns the search.
        def check(store, search)
          raise Error, "index_search_unknown_search" unless SEARCHES.include?(search)
          raise Error, "index_search_no_racetrack_setup" unless store.entry?("racetrack_setup")

          search
        end

        # 5a-1 and 5a-2, each filtered by the search's Dedupe as soon as
        # it's produced. plan is the EXPLAIN 5a-2 reads, and analyzed says
        # whether it has actual rows. Returns the Dedupe and the survivors.
        def mechanical(store, sql, plan:, analyzed:)
          statistics = PlannerStatistics.load(store).statistics
          dedupe = Dedupe.new(statistics:, low_cardinality: PiiClassification.load(store).low_cardinality)
          survivors = dedupe.filter(GeneratorOne.candidates(PgQuery.parse(sql), statistics)) +
                      dedupe.filter(GeneratorTwo.candidates(plan, statistics:, schemas: schemas(store), analyzed:))
          [dedupe, survivors]
        end

        def schemas(store) = store.read("relations").map { it["schema"] }.uniq

        # Each 3e set's values, in parameter order, as SingleCandidateTest
        # takes them.
        def values(maps)
          maps.transform_values do |map|
            map.keys.sort_by { Integer(it.delete_prefix("$")) }.map { map[it]["value"] }
          end
        end

        def entry(dedupe, report, maps)
          proposals = dedupe.proposals
          { "dedupe" => IndexStore.dedupe_plain(dedupe), "baseline" => plans(report.baseline.plans, maps),
            "results" => report.results.map { result(it, proposals, maps) } }
        end

        # Each set's plan: whether it used the candidate, its cost, and the
        # plan redacted through 3g against that set's own literals, so each
        # of them is its placeholder and any other literal is masked.
        def plans(plans, maps)
          plans.to_h do |set, plan|
            [set, { "used" => plan.used, "total_cost" => plan.total_cost,
                    "plan" => Redaction.plan(plan.raw_plan, maps.fetch(set)).explain }]
          end
        end

        # The candidate as the Dedupe holds it now, with the sources later
        # generators merged in.
        def result(result, proposals, maps)
          refusal = result.refusal && { "rule" => result.refusal.rule.to_s, "sqlstate" => result.refusal.sqlstate }
          { "candidate" => IndexStore.candidate_plain(proposals.find { it == result.candidate }),
            "partial_constant_only" => !result.candidate.predicate.nil?, "size" => result.size,
            "refusal" => refusal, "plans" => plans(result.plans, maps) }
        end
      end
    end
  end
end
