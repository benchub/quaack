# frozen_string_literal: true

require_relative "../schema_payload"
require_relative "../candidate_ddl_redaction"
require_relative "../index_store"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-payload --run <run ID> [--search original|rewrite_<n>]` (DESIGN.md
      # llm-index-ideas): sends the shape-only payload the driver gives the LLM, as one
      # index_payload message. It doesn't connect to anything.
      #
      # It reads the run's redacted_query, placeholder_shapes, redacted_plan,
      # schema_subset, and classification entries, and index_search_<search>,
      # which `quaacks index-search` wrote. It refuses an unknown search
      # (index_payload_unknown_search) and a run with no index search for it
      # (index_payload_no_index_search). The fields:
      #   query        the redacted query (redact)
      #   placeholders $n => { "type", "pattern", "elements", "est_rows",
      #                "actual_rows" }: the redact shape, and the rows of the
      #                input plan node that consumes it (nil unless exactly one does)
      #   plan         the redacted input plan's explain (redact), without its
      #                Settings, such as search_path, which llm-index-ideas doesn't need
      #   schema       the schema_subset entry (schema-dump), trimmed by SchemaPayload
      #   mechanical_results
      #                { "baseline" => { set => { "total_cost", "plan" } },
      #                  "candidates" => one per tested candidate, in test
      #                  order: { "ddl", "sources", "partial_constant_only",
      #                  "size", "refusal", "plans" => { set => { "used",
      #                  "total_cost", "plan" } } },
      #                  "set_aside" => [{ "ddl", "sources" }] }
      #                The plans are the stored ones, redacted through redact. Only the
      #                best candidate (see best) keeps each set's "plan".
      #   stats        the classification's outbound_statistics (classify)
      #
      # Trust boundary. Every field is shape-class except the candidates'
      # DDL: generator two reads the unredacted plan, so a stored predicate
      # or key expression can hold a real literal. Each DDL goes through
      # CandidateDdlRedaction, which masks every constant but a predicate value compared directly with its
      # own low-cardinality column, one of its MCV values (DESIGN.md's classify),
      # the values stats already carries.
      module IndexPayload
        OPTIONS = { "search" => :value }.freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = options.fetch("search", "original")
          raise Error, "index_payload_unknown_search" unless IndexSearch.llm_search?(store, search)
          raise Error, "index_payload_no_index_search" unless store.entry?("index_search_#{search}")

          [message(store, search, store.read("index_search_#{search}"))]
        end

        # For a rewrite (DESIGN.md's rewrite-index-ideas), query is the rewrite's SQL, which
        # holds only the original's $n and literals the LLM wrote, and plan
        # is its slow-literal plan as index-search stored it, redacted
        # through redact. placeholders stay the original's shapes and rows.
        def message(store, search, entry)
          stats = store.read("classification")["outbound_statistics"]
          query, plan = query_and_plan(store, search, entry)
          { type: :index_payload, query:, placeholders: placeholders(store),
            plan: plan.map { it.except("Settings") },
            schema: schema(store),
            mechanical_results: mechanical(entry, CandidateDdlRedaction.new(stats)), stats: }
        end

        def query_and_plan(store, search, entry)
          return [store.read("redacted_query"), store.read("redacted_plan")["explain"]] if search == "original"

          [store.read(search)["sql"], entry["baseline"]["slow"]["plan"]]
        end

        # Each placeholder's shape, typed as Postgres infers it for the
        # original query (index_search_original's parameter_types), or by
        # its redact type class when that's missing.
        def placeholders(store)
          inferred = store.entry?("index_search_original") && store.read("index_search_original")["parameter_types"]
          store.read("placeholder_shapes").to_h do |n, shape|
            rows = shape["rows"]
            [n, { "type" => (inferred && inferred[n]) || shape["type"], "pattern" => shape["pattern"],
                  "elements" => shape["elements"], "est_rows" => rows["estimated_rows"],
                  "actual_rows" => rows["actual_rows"] }]
          end
        end

        # The schema_subset entry, trimmed by SchemaPayload to the run's
        # relations and without pg_dump's noise.
        def schema(store) = SchemaPayload.subset(store.read("schema_subset"), store.read("relations"))

        def mechanical(entry, redaction)
          { "baseline" => entry["baseline"].transform_values { it.slice("total_cost", "plan") },
            "candidates" => entry["results"].map { result(it, redaction, best(entry["results"])) },
            "set_aside" => entry["dedupe"]["set_aside"].map { candidate(it, redaction) } }
        end

        # The unrefused candidate the planner used whose total cost, summed
        # over the literals, is lowest: the only one whose plans go out in full.
        def best(results)
          results.select { |r| !r["refusal"] && r["plans"].values.any? { it["used"] } }
                 .min_by { |r| r["plans"].values.sum { it["total_cost"] } }
        end

        def result(result, redaction, best)
          refusal = result["refusal"]
          plans = result.equal?(best) ? result["plans"] : result["plans"].transform_values { it.except("plan") }
          candidate(result["candidate"], redaction).merge(
            "partial_constant_only" => !result["candidate"]["predicate"].nil?, "size" => result["size"],
            "refusal" => refusal&.slice("rule", "sqlstate"), "plans" => plans
          )
        end

        def candidate(plain, redaction)
          { "ddl" => redaction.ddl(IndexStore.candidate(plain)), "sources" => plain["sources"] }
        end
      end
    end
  end
end
