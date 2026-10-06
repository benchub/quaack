# frozen_string_literal: true

require_relative "../burndown"
require_relative "../generator_three"
require_relative "../index_burndown"
require_relative "../index_store"
require_relative "../literal_set"
require_relative "../pii_classification"
require_relative "../planner_statistics"
require_relative "../run_server"
require_relative "../single_candidate_test"
require_relative "../table_name"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-test --run <run ID> [--search original]` (DESIGN.md's llm-index-ideas,
      # then index-test): filters the LLM's index DDL through the search's stored
      # Dedupe and tests the survivors on the racetrack. The driver calls it
      # once for the LLM's candidates and once more for its replacements.
      #
      # stdin is one JSON object, {"ddls": [String, ...]}, the LLM's CREATE
      # INDEX statements in its order, and nothing else. Anything else is
      # refused with index_test_bad_ddls. It refuses an unknown search
      # (index_test_unknown_search) and a run with no index search for it
      # (index_test_no_index_search), before connecting.
      #
      # On one racetrack connection, GeneratorThree.filter checks each DDL
      # (IndexDdlCheck, against the racetrack's catalog, with the input
      # plan's settings) and runs it through the Dedupe, and
      # SingleCandidateTest tests the accepted ones for each literal set, on
      # the search's own query: anchored_query, or the rewrite's SQL.
      # Then it rewrites index_search_<search> with the Dedupe as it is now,
      # and with each tested candidate appended to "llm_results", in the
      # same form as "results" (see IndexSearch). "baseline" and "results",
      # the mechanical ones, stay as they were.
      #
      # Without a round, it also writes index_generated_<search>, so `quaacks
      # status` shows llm-index-ideas ran; the driver calls it with no DDL when the LLM
      # proposed none.
      #
      # With --round refinement (DESIGN.md's llm-index-refine), each tested candidate also
      # carries "round" => "refinement", and the entry gets "refined" =>
      # true, even if nothing survived. Any other round is refused with
      # index_test_unknown_round.
      #
      # Before it writes anything else, it records the call's round in the
      # burndown (IndexBurndown.record_round), with its since taken from the
      # stored Dedupe in this process, so a replacement call counts only its
      # own DDL. Each call adds to its round's record, so a call that dies
      # after recording and is asked again counts both asks.
      #
      # It sends one index_outcome per DDL (see GeneratorThree), never the
      # DDL or a plan.
      module IndexTest
        OPTIONS = { "search" => :value, "round" => :value }.freeze
        ROUNDS = %w[refinement].freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, input:, **)
          search = options.fetch("search", "original")
          ddls = check(store, search, input, options)
          entry = store.read("index_search_#{search}")
          connection = Enclave::RunServer.connect(store, :racetrack)
          tested = run(store, search, entry, ddls, connection)
          save(store, search, entry, tested, options["round"])
          GeneratorThree.messages(tested[2])
        ensure
          connection&.close
        end

        # Records the round in the burndown, then rewrites the search's entry
        # and, without a round, writes the index_generated_<search> marker.
        # tested is run's.
        def save(store, search, entry, tested, round)
          IndexBurndown.record_round(store, search.to_sym, round, entry:, tested:)
          _, dedupe, _, report = tested
          store.write("index_search_#{search}", updated(entry, dedupe, report, LiteralSet.load(store).sets, round))
          store.write("index_generated_#{search}", true) unless round
        end

        def check(store, search, input, options)
          raise Error, "index_test_unknown_search" unless IndexSearch.llm_search?(store, search)
          raise Error, "index_test_unknown_round" unless [nil, *ROUNDS].include?(options["round"])
          raise Error, "index_test_no_index_search" unless store.entry?("index_search_#{search}")

          ddls = input["ddls"] if input.keys == ["ddls"]
          raise Error, "index_test_bad_ddls" unless ddls.is_a?(Array) && ddls.all?(String)

          ddls
        end

        # Filters and tests the DDL. Returns [since, dedupe, result, report]:
        # the stored Dedupe's counts before filtering, the Dedupe after,
        # GeneratorThree's result, and the SingleCandidateTest report.
        def run(store, search, entry, ddls, connection)
          dedupe = IndexStore.dedupe(entry["dedupe"], statistics: PlannerStatistics.load(store).statistics,
                                                      low_cardinality: PiiClassification.load(store).low_cardinality)
          since = Burndown.dedupe_counts(dedupe)
          result = GeneratorThree.filter(ddls, dedupe:, tables: tables(store),
                                               settings: store.read("plan")[0]["Settings"], connection:)
          [since, dedupe, result, test(store, search, connection, result.survivors)]
        end

        def tables(store) = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }

        # Tests the candidates against the search's own query (IndexSearch.query).
        def test(store, search, connection, candidates)
          literal_sets = IndexSearch.values(LiteralSet.load(store).sets)
          query = IndexSearch.query(store, search)
          SingleCandidateTest.run(connection, query:, literal_sets:, candidates:,
                                              types: IndexSearch.types(store, query))
        end

        def updated(entry, dedupe, report, maps, round)
          proposals = dedupe.proposals
          tested = report.results.map { IndexSearch.result(it, proposals, maps) }
          tested = tested.map { it.merge("round" => round) } if round
          entry.merge("dedupe" => IndexStore.dedupe_plain(dedupe),
                      "llm_results" => (entry["llm_results"] || []) + tested)
               .merge(round ? { "refined" => true } : {})
        end
      end
    end
  end
end
