# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_store"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-payload --run <run ID> [--search original]` (README
      # 5a-5): sends the shape-only payload the driver gives the LLM, as one
      # index_payload message. It doesn't connect to anything.
      #
      # It reads the run's redacted_query, placeholder_shapes, redacted_plan,
      # schema_subset, and classification entries, and index_search_<search>,
      # which `quaacks index-search` wrote. It refuses an unknown search
      # (index_payload_unknown_search) and a run with no index search for it
      # (index_payload_no_index_search). The fields:
      #   query        the redacted query (3g)
      #   placeholders $n => { "type", "pattern", "elements", "est_rows",
      #                "actual_rows" }: the 3g shape, and the rows of the
      #                step 1 plan node that consumes it (nil unless exactly one does)
      #   plan         the redacted step 1 plan's explain (3g)
      #   schema       the schema_subset entry (3b)
      #   mechanical_results
      #                { "baseline" => { set => { "total_cost", "plan" } },
      #                  "candidates" => one per tested candidate, in test
      #                  order: { "ddl", "sources", "partial_constant_only",
      #                  "size", "refusal", "plans" => { set => { "used",
      #                  "total_cost", "plan" } } },
      #                  "set_aside" => [{ "ddl", "sources" }] }
      #                The plans are the stored ones, redacted through 3g.
      #   stats        the classification's outbound_statistics (3f)
      #
      # Trust boundary. Every field is shape-class except the candidates'
      # DDL: generator two reads the unredacted plan, so a stored predicate
      # or key expression can hold a real literal. Each DDL goes through
      # CandidateDdlRedaction, which masks every constant that isn't a
      # low-cardinality MCV value of the candidate's table (README 3f),
      # the values stats already carries.
      module IndexPayload
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = options.fetch("search", "original")
          raise Error, "index_payload_unknown_search" unless IndexSearch::SEARCHES.include?(search)
          raise Error, "index_payload_no_index_search" unless store.entry?("index_search_#{search}")

          [message(store, store.read("index_search_#{search}"))]
        end

        def message(store, entry)
          stats = store.read("classification")["outbound_statistics"]
          { type: :index_payload, query: store.read("redacted_query"),
            placeholders: placeholders(store.read("placeholder_shapes")),
            plan: store.read("redacted_plan")["explain"], schema: store.read("schema_subset"),
            mechanical_results: mechanical(entry, CandidateDdlRedaction.new(stats)), stats: }
        end

        def placeholders(shapes)
          shapes.transform_values do |shape|
            rows = shape["rows"]
            { "type" => shape["type"], "pattern" => shape["pattern"], "elements" => shape["elements"],
              "est_rows" => rows["estimated_rows"], "actual_rows" => rows["actual_rows"] }
          end
        end

        def mechanical(entry, redaction)
          { "baseline" => entry["baseline"].transform_values { it.slice("total_cost", "plan") },
            "candidates" => entry["results"].map { result(it, redaction) },
            "set_aside" => entry["dedupe"]["set_aside"].map { candidate(it, redaction) } }
        end

        def result(result, redaction)
          refusal = result["refusal"]
          candidate(result["candidate"], redaction).merge(
            "partial_constant_only" => !result["candidate"]["predicate"].nil?, "size" => result["size"],
            "refusal" => refusal && refusal.slice("rule", "sqlstate"), "plans" => result["plans"]
          )
        end

        def candidate(plain, redaction)
          { "ddl" => redaction.ddl(IndexStore.candidate(plain)), "sources" => plain["sources"] }
        end
      end
    end
  end
end
