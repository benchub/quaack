# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_store"
require_relative "../refinement"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-feedback --run <run ID> [--search original]` (README
      # 5a-6): sends the 5a-4 results for the LLM's own 5a-5 candidates, and
      # which of them fell short (see Refinement), as one index_feedback
      # message. It doesn't connect to anything.
      #
      # It reads index_search_<search> and the classification entry, and
      # refuses an unknown search (index_feedback_unknown_search) and a run
      # with no index search for it (index_feedback_no_index_search). The
      # fields:
      #   revise     true if any candidate fell short, so 5a-6 should run
      #   refined    true if `quaacks index-test --round refinement` already
      #              ran for this search, so 5a-6 is done
      #   baseline   { set => total cost with no hypothetical index }
      #   candidates one per first-round LLM result, in order: { "ddl",
      #              "partial_constant_only", "size", "refusal" (nil or
      #              { "rule", "sqlstate" }), "plans" => { set => { "used",
      #              "total_cost", "plan" } }, "shortfall" (nil, "unused",
      #              or "beaten"), "beaten_by" (the simpler mechanical
      #              candidate's DDL, or nil) }
      #
      # Trust boundary. As in IndexPayload: the plans are the stored ones,
      # redacted through 3g, and every DDL goes through
      # CandidateDdlRedaction.
      module IndexFeedback
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = options.fetch("search", "original")
          raise Error, "index_feedback_unknown_search" unless IndexSearch::SEARCHES.include?(search)
          raise Error, "index_feedback_no_index_search" unless store.entry?("index_search_#{search}")

          entry = store.read("index_search_#{search}")
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          [message(entry, redaction)]
        end

        def message(entry, redaction)
          shortfalls = Refinement.shortfalls(entry)
          candidates = Refinement.first_round(entry).zip(shortfalls).map do |result, shortfall|
            candidate(result, shortfall, entry["results"], redaction)
          end
          { type: :index_feedback, revise: shortfalls.any?, refined: entry["refined"] == true,
            baseline: entry["baseline"].transform_values { it["total_cost"] }, candidates: }
        end

        def candidate(result, shortfall, mechanical, redaction)
          kind, index = shortfall
          { "ddl" => ddl(result, redaction), "partial_constant_only" => result["partial_constant_only"],
            "size" => result["size"], "refusal" => result["refusal"]&.slice("rule", "sqlstate"),
            "plans" => result["plans"], "shortfall" => kind,
            "beaten_by" => index && ddl(mechanical.fetch(index), redaction) }
        end

        def ddl(result, redaction) = redaction.ddl(IndexStore.candidate(result["candidate"]))
      end
    end
  end
end
