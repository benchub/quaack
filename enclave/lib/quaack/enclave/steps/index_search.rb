# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_entry"
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
require_relative "../structural_discard"
require_relative "../unused_set_aside"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-search --run <run ID> [--search original|rewrite_<n>]`
      # (DESIGN.md's index-search, index-from-query to index-test, and plan-pruning): the mechanical half of the
      # index search, on the racetrack that `quaacks racetrack-setup` set up.
      # A rewrite search runs rewrite_entry on the stored rewrite's SQL, with
      # no plan gate.
      #
      # It refuses an unknown search (index_search_unknown_search: neither
      # original nor a stored rewrite_<n>) and a run with no racetrack_setup
      # marker (index_search_no_racetrack_setup), before connecting. Then,
      # on one racetrack connection: the plan gate on anchored_query; index-from-query
      # on the parse of anchored_query and index-from-plan on the input plan, each
      # filtered by one Dedupe (index-dedupe) as soon as it's produced; and index-test on
      # the survivors, for each literal set.
      #
      # It writes one entry, index_search_<search>, only when all of that
      # succeeds:
      #   "dedupe"   => the Dedupe, as IndexStore saves it, so llm-index-ideas'
      #                 index-test can go on with the same search
      #   "baseline" => { set name => a plan, as below, with no hypothetical
      #                 index }
      #   "results"  => one per tested candidate, in test order (the
      #                 Dedupe's proposals): { "candidate" (as IndexStore
      #                 saves it, sources merged), "partial_constant_only"
      #                 (DESIGN.md's llm-index-ideas' tag: true for a partial index, which
      #                 works only when the predicate's literal is a constant
      #                 in the application's SQL), "size", "refusal" (nil or
      #                 { "rule", "sqlstate" }), "plans" => { set name =>
      #                 { "used", "total_cost", "plan" } } }
      #   "set_aside" => the tested candidates (as IndexStore saves them)
      #                 that index-test found unused but that index-build builds for real
      #                 anyway (see UnusedSetAside)
      #   "parameter_types" => { $n => the type Postgres infers for it }
      #                 (the original only: llm-index-ideas, llm-rewrites, and vacuity-guard send it)
      # "plan" is the EXPLAIN redacted through redact (Redaction.plan) against
      # that set's own literals, so it holds placeholders, never a literal.
      # Raw plans aren't saved.
      #
      # The racetrack is production data and candidates can hold literals,
      # so nothing here goes out. Its only line is DONE, and a failure names
      # only its rule.
      module IndexSearch
        OPTIONS = { "search" => :value }.freeze
        # A rewrite search names the rewrite_<n> entry rewrite-check stored.
        REWRITE = /\Arewrite_[1-9][0-9]*\z/

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
          connection = Enclave::RunServer.connect(store, :racetrack)
          store.write("index_search_#{search}", search_entry(store, connection, search))
          []
        ensure
          connection&.close
        end

        # The search's entry: the original's behind the plan gate, or a
        # stored rewrite's (DESIGN.md's plan-pruning).
        def search_entry(store, connection, search)
          return rewrite_entry(store, connection, RewriteEntry.run_sql(store.read(search))) unless search == "original"

          sql = store.read("anchored_query")
          PlanGate.check(store:, connection:, sql:)
          original_entry(store, connection, sql)
        end

        # The search's query: anchored_query, or the rewrite's SQL.
        def query(store, search)
          search == "original" ? store.read("anchored_query") : RewriteEntry.run_sql(store.read(search))
        end

        # Whether search names a search: original, or a stored rewrite_<n>.
        def search?(store, search)
          search == "original" || (REWRITE.match?(search) && store.entry?(search))
        end

        # Whether the LLM-side steps (llm-index-ideas, llm-index-refine) take search: original, or
        # (DESIGN.md's rewrite-index-ideas) a stored rewrite_<n> that survived rewrite-test and counterexamples
        # (rewrite_survived_<n> says survived true) and that plan-pruning didn't
        # prune (rewrite_pruned_<n> doesn't say discarded true).
        def llm_search?(store, search)
          return search == "original" unless search.is_a?(String) && REWRITE.match?(search) && store.entry?(search)

          n = search.delete_prefix("rewrite_")
          survived = store.entry?("rewrite_survived_#{n}") && store.read("rewrite_survived_#{n}")["survived"] == true
          pruned = store.entry?("rewrite_pruned_#{n}") && store.read("rewrite_pruned_#{n}")["discarded"] == true
          survived && !pruned
        end

        # index-from-query to index-test for the original, on the input plan.
        def original_entry(store, connection, sql)
          dedupe, candidates = mechanical(store, sql, plan: store.read("plan"), analyzed: true)
          maps = LiteralSet.load(store).sets
          types = types(store, sql)
          report = SingleCandidateTest.run(connection, query: sql, literal_sets: values(maps), candidates:, types:)
          entry(store, dedupe, report, maps).merge("parameter_types" => parameter_types(connection, sql, types))
        end

        # Each $n's type for PREPARE: its original literal's (Redaction's
        # placeholder map), so Postgres doesn't infer a different one.
        def types(store, sql) = Redaction.binding(sql, Redaction.placeholder_map(store)).types

        # $n => the type Postgres gives it in sql, prepared with types (see
        # types), by catalog name (format_type), or {} if sql doesn't
        # prepare. Shape-class.
        def parameter_types(connection, sql, types)
          oids = StructuralDiscard.parameter_types(connection, sql, types) || []
          names = oids.map { connection.exec_params("SELECT format_type($1::oid, NULL)", [it]).getvalue(0, 0) }
          names.each_with_index.to_h { |name, i| ["$#{i + 1}", name] }
        end

        # DESIGN.md's plan-pruning: the same search for one rewrite candidate, sql, as
        # the inbound check accepted it, with the original's $n. index-from-query runs on
        # its parse, and index-from-plan on its plain EXPLAIN on the racetrack with the
        # slow literals (analyzed: false, since a rewrite has no production
        # EXPLAIN ANALYZE). Its Dedupe is its own, so index-dedupe compares only
        # against existing indexes and its own proposals. index-test runs the
        # rewrite. It returns the entry, in the index_search_<search> form,
        # for the caller to store. There's no plan gate: the rewrite has no
        # production plan to compare with.
        def rewrite_entry(store, connection, sql)
          maps = LiteralSet.load(store).sets
          literal_sets = values(maps)
          types = types(store, sql)
          plan = slow_plan(connection, sql, literal_sets, types)
          dedupe, candidates = mechanical(store, sql, plan:, analyzed: false)
          entry(store, dedupe, SingleCandidateTest.run(connection, query: sql, literal_sets:, candidates:, types:),
                maps)
        end

        # The query's plain EXPLAIN with the slow literals.
        def slow_plan(connection, sql, literal_sets, types)
          report = SingleCandidateTest.run(connection, query: sql, literal_sets: literal_sets.slice("slow"),
                                                       candidates: [], types:)
          report.baseline.plans.fetch("slow").raw_plan
        end

        # The refusals made before connecting. Returns the search.
        def check(store, search)
          raise Error, "index_search_unknown_search" unless search.is_a?(String) && search?(store, search)
          raise Error, "index_search_no_racetrack_setup" unless store.entry?("racetrack_setup")

          search
        end

        # index-from-query and index-from-plan, each filtered by the search's Dedupe as soon as
        # it's produced. plan is the EXPLAIN index-from-plan reads, and analyzed says
        # whether it has actual rows. Returns the Dedupe and the survivors.
        def mechanical(store, sql, plan:, analyzed:)
          statistics = PlannerStatistics.load(store).statistics
          dedupe = Dedupe.new(statistics:, low_cardinality: PiiClassification.load(store).low_cardinality)
          survivors = dedupe.filter(GeneratorOne.candidates(PgQuery.parse(sql), statistics)) +
                      dedupe.filter(GeneratorTwo.candidates(plan, statistics:, schemas: schemas(store), analyzed:))
          [dedupe, survivors]
        end

        def schemas(store) = store.read("relations").map { it["schema"] }.uniq

        # Each literals set's values, in parameter order, as SingleCandidateTest
        # takes them.
        def values(maps)
          maps.transform_values do |map|
            map.keys.sort_by { Integer(it.delete_prefix("$")) }.map { map[it]["value"] }
          end
        end

        def entry(store, dedupe, report, maps)
          proposals = dedupe.proposals
          set_aside = UnusedSetAside.select(report, PiiClassification.load(store).low_cardinality)
                                    .map { |c| IndexStore.candidate_plain(proposals.find { it == c }) }
          { "dedupe" => IndexStore.dedupe_plain(dedupe), "baseline" => plans(report.baseline.plans, maps),
            "results" => report.results.map { result(it, proposals, maps) },
            "set_aside" => set_aside }
        end

        # Each set's plan: whether it used the candidate, its cost, and the
        # plan redacted through redact against that set's own literals, so each
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
