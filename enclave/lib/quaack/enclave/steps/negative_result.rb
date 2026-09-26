# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_store"

module Quaack
  module Enclave
    module Steps
      # README 15a, for ReportPayload's negative field when the selection is
      # empty: which rewrites steps 9 and 10 disproved, which index
      # candidates 5a-4 found the planner never used or HypoPG refused, and
      # which the 5a-3 Dedupe dropped as covered by an existing index.
      #
      # Trust boundary. Rule, scenario, and search names, round numbers,
      # SQLSTATEs, existing index names (schema), and DDL through
      # CandidateDdlRedaction. Never a plan or a literal.
      module NegativeResult
        module_function

        # README 15a. Rule and scenario names, round numbers, redacted DDL,
        # existing index names, and SQLSTATEs only.
        def call(store)
          rewrites = (1..).lazy.map { "rewrite_#{it}" }.take_while { store.entry?(it) }.to_a
          searches = ["original", *rewrites].select { store.entry?("index_search_#{it}") }
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          { "disproved" => rewrites.filter_map { disproved(store, it) },
            "declined" => searches.flat_map { declined(store, it, redaction) },
            "existing" => searches.flat_map { existing(store, it, redaction) } }
        end

        def disproved(store, search)
          number = search.delete_prefix("rewrite_")
          tested = store.entry?("rewrite_tested_#{number}") && store.read("rewrite_tested_#{number}")
          return unless tested
          return disproof(search, "step9", tested["rule"], tested["scenario"], nil) unless tested["passed"]

          survived = store.entry?("rewrite_survived_#{number}") && store.read("rewrite_survived_#{number}")
          return unless survived && survived["survived"] == false

          disproof(search, "step10", nil, nil, store.read("rewrite_round_#{number}")["round"])
        end

        def disproof(rewrite, step, rule, scenario, round)
          { "rewrite" => rewrite, "step" => step, "rule" => rule, "scenario" => scenario, "round" => round }
        end

        def declined(store, search, redaction)
          entry = store.read("index_search_#{search}")
          [*entry["results"], *entry["llm_results"]].filter_map do |result|
            refusal = result["refusal"]
            next if refusal.nil? && result["plans"].values.any? { it["used"] }

            { "search" => search, "ddl" => redaction.ddl(IndexStore.candidate(result["candidate"])),
              "reason" => refusal ? refusal["rule"] : "unused", "sqlstate" => refusal&.fetch("sqlstate") }
          end
        end

        def existing(store, search, redaction)
          store.read("index_search_#{search}").dig("dedupe", "drops").to_a.filter_map do |drop|
            next unless drop["reason"] == "covered_by_existing"

            { "search" => search, "ddl" => redaction.ddl(IndexStore.candidate(drop["candidate"])),
              "covered_by" => drop["covered_by"]["existing"] }
          end
        end
      end
    end
  end
end
