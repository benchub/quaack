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
        REWRITE = /\Arewrite_[1-9]\d*\z/

        module_function

        # README 15a. Rule and scenario names, round numbers, redacted DDL,
        # existing index names, and SQLSTATEs only.
        def call(store)
          rewrites = rewrites(store)
          searches = ["original", *rewrites].select { store.entry?("index_search_#{it}") }
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          { "disproved" => rewrites.filter_map { disproved(store, it) },
            "declined" => searches.flat_map { declined(store, it, redaction) },
            "existing" => searches.flat_map { existing(store, it, redaction) },
            "knocked_out" => knocked_out(store) }
        end

        # Every stored rewrite_<n>, in number order, gaps and all.
        def rewrites(store) = store.entry_names.grep(REWRITE).sort_by { it.delete_prefix("rewrite_").to_i }

        # The entry's data, or nil if the run doesn't hold it.
        def optional(store, name) = (store.read(name) if store.entry?(name))

        # The excluded labels whose rewrite survived steps 9 and 10, with
        # the 14d reason: minimax's not_better or footprint_tie, or 14c's
        # result_mismatch.
        def knocked_out(store)
          store.read("selection")["excluded"].filter_map do |label, reason|
            number = label.split(":").first[/\Arewrite_(\d+)\z/, 1] or next
            next unless optional(store, "rewrite_survived_#{number}")&.fetch("survived") == true

            { "label" => label, "reason" => reason }
          end
        end

        def disproved(store, search)
          number = search.delete_prefix("rewrite_")
          tested = optional(store, "rewrite_tested_#{number}") or return
          return disproof(search, "step9", tested["rule"], tested["scenario"], nil) unless tested["passed"]

          return unless optional(store, "rewrite_survived_#{number}")&.fetch("survived") == false

          disproof(search, "step10", nil, nil, optional(store, "rewrite_round_#{number}")&.fetch("round"))
        end

        def disproof(rewrite, step, rule, scenario, round)
          { "rewrite" => rewrite, "step" => step, "rule" => rule, "scenario" => scenario, "round" => round }
        end

        def declined(store, search, redaction)
          entry = store.read("index_search_#{search}")
          set_aside = entry.fetch("set_aside", []).map { IndexStore.candidate(it) }
          [*entry["results"], *entry["llm_results"]].filter_map do |result|
            refusal = result["refusal"]
            next if refusal.nil? && kept?(result, set_aside)

            { "search" => search, "ddl" => redaction.ddl(IndexStore.candidate(result["candidate"])),
              "reason" => refusal ? refusal["rule"] : "unused", "sqlstate" => refusal&.fetch("sqlstate") }
          end
        end

        # A tested candidate the planner used, or one set aside for 12a to
        # build for real (20260927-11). Neither was declined.
        def kept?(result, set_aside)
          result["plans"].values.any? { it["used"] } || set_aside.include?(IndexStore.candidate(result["candidate"]))
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
