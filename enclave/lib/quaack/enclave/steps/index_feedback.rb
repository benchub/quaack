# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_store"
require_relative "../internal_error_log"
require_relative "../refinement"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-feedback --run <run ID> [--search original]` (DESIGN.md
      # llm-index-refine): sends the index-test results for the LLM's own llm-index-ideas candidates, and
      # which of them fell short (see Refinement), as one index_feedback
      # message. It doesn't connect to anything.
      #
      # It reads index_search_<search> and the classification entry, and
      # refuses an unknown search (index_feedback_unknown_search) and a run
      # with no index search for it (index_feedback_no_index_search). The
      # fields:
      #   revise     true if any candidate fell short, so llm-index-refine should run
      #   refined    true if `quaacks index-test --round refinement` already
      #              ran for this search, so llm-index-refine is done
      #   baseline   { set => total cost with no hypothetical index }
      #   candidates one per first-round LLM result, in order: { "ddl",
      #              "partial_constant_only", "size", "refusal" (nil or
      #              { "rule", "sqlstate" }), "plans" => { set => { "used",
      #              "total_cost", "plan" } }, "shortfall" (nil, "unused",
      #              or "beaten"), "beaten_by" (the simpler mechanical
      #              candidate's DDL, or nil) }
      #
      # Trust boundary. As in IndexPayload: the plans are the stored ones,
      # redacted through redact, and every DDL goes through
      # CandidateDdlRedaction. A candidate whose DDL fails its outbound
      # check is withheld (20261124-233000-1): left out of candidates,
      # counted in withheld, and only its shape logged to internal_errors.log.
      module IndexFeedback
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = options.fetch("search", "original")
          raise Error, "index_feedback_unknown_search" unless IndexSearch.llm_search?(store, search)
          raise Error, "index_feedback_no_index_search" unless store.entry?("index_search_#{search}")

          entry = store.read("index_search_#{search}")
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          message = message(entry, redaction)
          log_withheld(store, "index-feedback", redaction)
          [message]
        end

        # Writes each candidate redaction withheld to the run's
        # internal_errors.log, by its shape alone (20261124-233000-1).
        def log_withheld(store, step, redaction)
          redaction.withheld.each { InternalErrorLog.withheld(store.path, step:, fingerprint: it) }
        end

        def message(entry, redaction)
          shortfalls = Refinement.shortfalls(entry)
          candidates = Refinement.first_round(entry).zip(shortfalls).map do |result, shortfall|
            candidate(result, shortfall, entry["results"], redaction)
          end
          { type: :index_feedback, revise: shortfalls.any?, refined: entry["refined"] == true,
            baseline: entry["baseline"].transform_values { it["total_cost"] }, candidates: candidates.compact,
            withheld: candidates.count(nil) }
        end

        # nil when the candidate's DDL is withheld.
        def candidate(result, shortfall, mechanical, redaction)
          kind, index = shortfall
          shown = withholding(result, redaction) or return
          { "ddl" => shown, "partial_constant_only" => result["partial_constant_only"],
            "size" => result["size"], "refusal" => result["refusal"]&.slice("rule", "sqlstate"),
            "plans" => result["plans"], "shortfall" => kind,
            "beaten_by" => index && withholding(mechanical.fetch(index), redaction) }
        end

        def withholding(result, redaction) = redaction.withholding_ddl(IndexStore.candidate(result["candidate"]))

        def ddl(result, redaction) = redaction.outbound_ddl(IndexStore.candidate(result["candidate"]))
      end
    end
  end
end
