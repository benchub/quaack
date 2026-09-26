# frozen_string_literal: true

require_relative "../generator_three"
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
      # `quaacks index-test --run <run ID> [--search original]` (README 5a-5,
      # then 5a-4): filters the LLM's index DDL through the search's stored
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
      # (IndexDdlCheck, against the racetrack's catalog, with the step 1
      # plan's settings) and runs it through the Dedupe, and
      # SingleCandidateTest tests the accepted ones for each 3e literal set.
      # Then it rewrites index_search_<search> with the Dedupe as it is now,
      # and with each tested candidate appended to "llm_results", in the
      # same form as "results" (see IndexSearch). "baseline" and "results",
      # the mechanical ones, stay as they were.
      #
      # It sends one index_outcome per DDL (see GeneratorThree), never the
      # DDL or a plan.
      module IndexTest
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, input:, **)
          search = options.fetch("search", "original")
          ddls = check(store, search, input)
          key = "index_search_#{search}"
          entry = store.read(key)
          connection = Enclave::RunServer.connect(store, :racetrack)
          result, report, dedupe = run(store, entry, ddls, connection)
          store.write(key, updated(entry, dedupe, report, LiteralSet.load(store).sets))
          GeneratorThree.messages(result)
        ensure
          connection&.close
        end

        def check(store, search, input)
          raise Error, "index_test_unknown_search" unless IndexSearch::SEARCHES.include?(search)
          raise Error, "index_test_no_index_search" unless store.entry?("index_search_#{search}")

          ddls = input["ddls"] if input.keys == ["ddls"]
          raise Error, "index_test_bad_ddls" unless ddls.is_a?(Array) && ddls.all?(String)

          ddls
        end

        def run(store, entry, ddls, connection)
          dedupe = IndexStore.dedupe(entry["dedupe"], statistics: PlannerStatistics.load(store).statistics,
                                                      low_cardinality: PiiClassification.load(store).low_cardinality)
          tables = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          result = GeneratorThree.filter(ddls, dedupe:, tables:, settings: store.read("plan")[0]["Settings"],
                                               connection:)
          report = SingleCandidateTest.run(connection, query: store.read("anchored_query"),
                                                       literal_sets: IndexSearch.values(LiteralSet.load(store).sets),
                                                       candidates: result.survivors)
          [result, report, dedupe]
        end

        def updated(entry, dedupe, report, maps)
          proposals = dedupe.proposals
          entry.merge("dedupe" => IndexStore.dedupe_plain(dedupe),
                      "llm_results" => (entry["llm_results"] || []) +
                                       report.results.map { IndexSearch.result(it, proposals, maps) })
        end
      end
    end
  end
end
