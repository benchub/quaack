# frozen_string_literal: true

require_relative "../burndown"
require_relative "../candidate_ddl_redaction"
require_relative "../clock_anchoring"
require_relative "../dedupe"
require_relative "../index_candidate"
require_relative "../planner_statistics"
require_relative "../table_name"
require_relative "negative_result"

module Quaack
  module Enclave
    module Steps
      # `quaacks report-payload --run <run ID>` (DESIGN.md step 15): sends the
      # shape-class data the driver renders the main report from, as one
      # report message. It reads the store only and connects to nothing.
      #
      #   top, excluded, infinite_sets  the selection entry (14d)
      #   verdicts         minimax's per-literal verdicts (14a, 14b)
      #   measurements     { "original" | label => { set => { "total_blocks",
      #                    "hit", "read", "stable", "timed_out" } } } for the
      #                    original and each top candidate; hit and read are
      #                    the run with the most blocks
      #   candidates       one per top label: { "label", "sql", "indexes",
      #                    "plan", "untested_atoms", "evidence" }
      #   indexes          { built index name => { "ddl", "size",
      #                    "covered_by", "makes_redundant" } }
      #   original_plan    the redacted step 1 plan's node shapes
      #   timed_out_count  candidate runs dropped for timing out
      #   negative         nil unless top is empty (DESIGN.md 15a); then
      #                    { "disproved" => [{ "rewrite", "step" (step9 or
      #                    step10), "rule", "scenario", "round" }],
      #                    "declined" => [{ "search", "ddl", "reason"
      #                    (unused or the 5a-4 refusal rule), "sqlstate" }],
      #                    "existing" => [{ "search", "ddl", "covered_by"
      #                    (the existing index's name) }],
      #                    "knocked_out" => [{ "label", "reason" (the 14d
      #                    excluded reason) }] }
      #   burndown         { "stages", "totals" }, the 15b counts as
      #                    Burndown.read checks them: names and counts only
      #
      # Trust boundary. sql is the anchored query with the 3h functions put
      # back (the 3g redacted query, literals as $n) for an index-only
      # candidate, or the stored rewrite's SQL, which holds only $n and what
      # the LLM wrote. DDL goes through CandidateDdlRedaction. A plan node
      # sends only its type, relation, index name, and row counts, never a
      # Filter or Index Cond. Measurements are counts. Index names and
      # relations are schema.
      module ReportPayload
        module_function

        def call(store:, **)
          selection = store.read("selection")
          labels = selection["top"].map { it["label"] }
          [{ type: :report, **selection.slice("top", "excluded", "infinite_sets").transform_keys(&:to_sym),
             verdicts: store.read("minimax")["verdicts"].slice(*labels),
             measurements: measurements(store, labels), **shapes(store, labels),
             timed_out_count: store.read("candidate_runs")["timed_out_count"],
             negative: labels.empty? ? NegativeResult.call(store) : nil, burndown: Burndown.read(store) }]
        end

        def shapes(store, labels)
          stats = PlannerStatistics.load(store).statistics
          build = store.read("index_build")
          { candidates: labels.map { candidate(store, it, build, stats) }, indexes: indexes(store, build, stats),
            original_plan: nodes(store.read("redacted_plan")["explain"], stats) }
        end

        def measurements(store, labels)
          runs = store.read("candidate_runs")["candidates"]
          index = store.read("index_baseline")["combinations"]
          out = labels.to_h { [it, runs.dig(it.split(":").first, it.end_with?(":none") ? "none" : it) || index[it]] }
          { "original" => store.read("baseline")["sets"], **out }.transform_values do |sets|
            sets.transform_values { summary(it) }
          end
        end

        def summary(measurement)
          return { "timed_out" => true } if measurement["timed_out"]

          worst = measurement["runs"].max_by { it["total_blocks"] }
          { "total_blocks" => measurement["total_blocks"], "hit" => worst["hit"], "read" => worst["read"],
            "stable" => measurement["stable"], "timed_out" => false }
        end

        def candidate(store, label, build, stats)
          search = label.split(":").first
          out = { "label" => label, "indexes" => build["combinations"].fetch(label, []) }
          return out.merge("sql" => original_sql(store), "plan" => nil) if search == "original"

          out.merge("sql" => store.read(search)["sql"], "plan" => rewrite_plan(store, search, stats),
                    **checks(store, search.delete_prefix("rewrite_")))
        end

        def rewrite_plan(store, search, stats)
          entry = "index_search_#{search}"
          plan = store.read(entry).dig("baseline", "slow", "plan") if store.entry?(entry)
          plan && nodes(plan, stats)
        end

        # Step 9's untested atoms, and whether step 10 had evidence on them.
        def checks(store, number)
          { "untested_atoms" => store.read("rewrite_tested_#{number}")["untested_atoms"],
            "evidence" => store.read("rewrite_survived_#{number}").fetch("evidence", true) }
        end

        def original_sql(store)
          clock = store.read("clock_replacements")
          replacements = clock["replacements"].map { ClockAnchoring::Replacement.new(**it.transform_keys(&:to_sym)) }
          added = clock["added_names"].map { ClockAnchoring::AddedName.new(**it.transform_keys(&:to_sym)) }
          ClockAnchoring.restore(store.read("anchored_query"), replacements, added)
        end

        def indexes(store, build, stats)
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          build["indexes"].transform_values do |built|
            proposed = IndexCandidate.from_ddl(built["ddl"], sources: [:llm])
            { "ddl" => proposed && redaction.ddl(proposed), "size" => built["size"], **coverage(proposed, stats) }
          end
        end

        # The existing index (by name, from the catalog) that covers
        # proposed as a prefix, and the existing ones proposed covers.
        def coverage(proposed, stats)
          existing = proposed && stats.table?(proposed.table) ? stats.table(proposed.table).indexes.compact : {}
          { "covered_by" => existing.find { |_, e| Dedupe.covers?(e, proposed) }&.first,
            "makes_redundant" => existing.select { |_, e| Dedupe.covers?(proposed, e) }.keys }
        end

        def nodes(explain, stats)
          flatten(explain.first["Plan"]).map do |plan|
            table = table(plan, stats)
            { "node" => plan["Node Type"], "relation" => table && "#{table.schema}.#{table.name}",
              "index" => plan["Index Name"], "est_rows" => plan["Plan Rows"], "actual_rows" => plan["Actual Rows"],
              "selectivity" => selectivity(plan, table, stats) }
          end
        end

        # The node's table, by its Schema if the plan is VERBOSE, or else
        # the one subset table of that name. nil if neither finds one.
        def table(plan, stats)
          name = plan["Relation Name"] or return
          return TableName.new(schema: plan["Schema"], name:) if plan["Schema"]

          matches = stats.tables.keys.select { it.name == name }
          matches.first if matches.size == 1
        end

        # The node's rows over its table's reltuples, or nil.
        def selectivity(plan, table, stats)
          tuples = stats.table(table).reltuples if table && stats.table?(table)
          return unless tuples&.positive?

          ((plan["Actual Rows"] || plan["Plan Rows"]).to_f / tuples).round(6)
        end

        def flatten(plan) = [plan, *plan.fetch("Plans", []).flat_map { flatten(it) }]
      end
    end
  end
end
