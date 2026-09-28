# frozen_string_literal: true

require_relative "../index_ranking"
require_relative "../index_store"
require_relative "../literal_set"
require_relative "../run_server"
require_relative "../single_candidate_test"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-rank --run <run ID> [--search original|rewrite_<n>]`
      # (DESIGN.md 5a-7, and step 8 for a rewrite, ranked with its own query):
      # ranks and combines every candidate of index_search_<search>
      # the planner used, mechanical and LLM alike, on the racetrack.
      #
      # It refuses an unknown search (index_rank_unknown_search) and a run
      # with no index search for it (index_rank_no_index_search), before
      # connecting. The store keeps 5a-4's redacted plans but not its
      # canonical plans, so it tests the used candidates again with 5a-4,
      # then runs IndexRanking on that report. It writes
      # index_ranking_<search>:
      #   "top"         up to three single-index entries, best first
      #   "combination" the best combination of two or three, or nil
      # Each entry is { "ddl" => [String], "size", "costs" => { set =>
      # { "before", "after" } }, "used" => { set => [Boolean] }, "partial",
      # "plans" => { set => its plan, redacted through 3g as IndexSearch
      # stores plans } } (DESIGN.md 5a-7's canonical plans, for step 13).
      # The DDL can hold a low-cardinality predicate literal, so the entry
      # stays in the store. Once 5a-5 has run for the search
      # (index_generated_<search>), it also writes index_llm_ranked_<search>,
      # so a resumed step 11 knows its second 5a-7 ran. Its only line is DONE.
      module IndexRank
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = options.fetch("search", "original")
          raise Error, "index_rank_unknown_search" unless search.is_a?(String) && IndexSearch.search?(store, search)
          raise Error, "index_rank_no_index_search" unless store.entry?("index_search_#{search}")

          connection = Enclave::RunServer.connect(store, :racetrack)
          store.write("index_ranking_#{search}", ranking(store, search, connection))
          store.write("index_llm_ranked_#{search}", true) if store.entry?("index_generated_#{search}")
          []
        ensure
          connection&.close
        end

        def ranking(store, search, connection)
          entry = store.read("index_search_#{search}")
          query = IndexSearch.query(store, search)
          literal_sets = IndexSearch.values(LiteralSet.load(store).sets)
          types = IndexSearch.types(store, query)
          report = SingleCandidateTest.run(connection, query:, literal_sets:, candidates: used(entry), types:)
          ranking = IndexRanking.rank(connection, query:, literal_sets:, baseline: report.baseline,
                                                  results: report.results, types:)
          plain_ranking(ranking, LiteralSet.load(store).sets)
        end

        def plain_ranking(ranking, maps)
          { "top" => ranking.top.map { plain(it, maps) },
            "combination" => ranking.combination && plain(ranking.combination, maps) }
        end

        def used(entry)
          (entry["results"] + (entry["llm_results"] || []))
            .select { !it["refusal"] && it["plans"].values.any? { |plan| plan["used"] } }
            .map { IndexStore.candidate(it["candidate"]) }
        end

        def plain(entry, maps)
          { "ddl" => entry.ddl, "size" => entry.size,
            "costs" => entry.costs.transform_values { { "before" => it.before, "after" => it.after } },
            "used" => entry.used, "partial" => entry.partial,
            "plans" => IndexSearch.plans(entry.plans, maps).transform_values { it["plan"] } }
        end
      end
    end
  end
end
