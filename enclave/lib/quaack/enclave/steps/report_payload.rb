# frozen_string_literal: true

require_relative "../burndown"
require_relative "../candidate_ddl_redaction"
require_relative "../clock_anchoring"
require_relative "../dedupe"
require_relative "../index_candidate"
require_relative "../planner_statistics"
require_relative "../table_name"
require_relative "existing_indexes"
require_relative "measured_labels"
require_relative "negative_result"
require_relative "rewrite_fate"
require_relative "rewrite_source"
require_relative "rule_bugs"

module Quaack
  module Enclave
    module Steps
      # `quaacks report-payload --run <run ID>` (DESIGN.md's report): sends the
      # shape-class data the driver renders the main report from, as one
      # report message. It reads the store only and connects to nothing.
      #
      #   original_sql     the original query, always: the redacted query
      #                    (literals as $n) with the clock-anchor clock functions put
      #                    back
      #   original_plan    the redacted input plan's node shapes
      #   original_measurements  { set => { "total_blocks", "hit", "read",
      #                    "stable", "timed_out" } }, the bare original's
      #                    baseline; hit and read are the run with the most
      #                    blocks
      #   top, excluded, infinite_sets  the selection entry
      #   labels           one per measured label, ranked or not
      #                    (MeasuredLabels): { "label", "search" (original
      #                    or rewrite_<n>), "indexes" (built names),
      #                    "measurements", "verdicts" (minimax's, per
      #                    literal set), "timed_out" }
      #   rewrites         one per stored rewrite, ranked or not: {
      #                    "rewrite" (rewrite_<n>), "sql", "source" (rule,
      #                    llm, or operator), "rules", and "empirical"
      #                    (the denormalized_equal assumptions it rests
      #                    on) (RewriteSource),
      #                    "fate" and its "scenario", "rule", "round",
      #                    "after", and "cycle" (RewriteFate; cycle is an
      #                    fk_cycle refusal's tables, "schema.name" in
      #                    foreign key order), "plan" (its node shapes on
      #                    the slow literal set, or nil), "untested_atoms"
      #                    (rewrite-test's, or nil if it wasn't tested), and
      #                    "evidence" (whether a counterexamples round compared it
      #                    on loaded inserts; nil unless it survived) }
      #   indexes          { built index name => { "ddl", "size",
      #                    "covered_by" (nil or an existing index),
      #                    "makes_redundant" (existing indexes) } }, each
      #                    existing index as { "name", "size_bytes" }
      #                    (ExistingIndexes)
      #   timed_out_count  candidate runs dropped for timing out
      #   negative         nil unless top is empty (DESIGN.md's negative-result); then
      #                    NegativeResult's { "declined", "existing" }, each
      #                    index once, with the searches it came up in
      #   rule_bugs        [{ "rewrite", "rules", "step" (rewrite-test, counterexamples, or
      #                    result-comparison) }]: each rule-made rewrite a test disproved
      #                    (never a result-comparison timeout, which compares nothing,
      #                    nor a rewrite-test or counterexamples disproof of one resting on
      #                    a denormalized_equal assumption),
      #                    a bug in QUAACK (DESIGN.md's rewrite-rules, RuleBugs), sent
      #                    whether or not top is empty
      #   burndown         { "stages", "totals" }, the burndown counts as
      #                    Burndown.read checks them: names and counts only
      #
      # A rewrite the enclave refused on arrival isn't stored, so nothing is
      # sent for it. The burndown counts those.
      #
      # Trust boundary. original_sql is the anchored query with the clock-anchor
      # functions put back (the redacted query, literals as $n). A
      # rewrite's sql is the stored rewrite's SQL, which holds only $n and
      # what the LLM, a rule, or the operator wrote, as the inbound check
      # accepted it. DDL goes through CandidateDdlRedaction. A plan node
      # sends only its type, relation, index name, and row counts, never a
      # Filter or Index Cond. Measurements are counts. Index names and
      # relations are schema. A source, a rule name, a fate, and a fate's
      # details are QUAACK's own constants: RewriteSource and RewriteFate
      # send no other, but for an fk_cycle's tables, which are schema and
      # each one the schema_subset entry holds. Untested atoms are rewrite-test's redacted shapes.
      module ReportPayload
        module_function

        def call(store:, **)
          selection = store.read("selection")
          stats = PlannerStatistics.load(store).statistics
          [{ type: :report, **selection.slice("top", "excluded", "infinite_sets").transform_keys(&:to_sym),
             **original(store, stats), labels: MeasuredLabels.call(store), rewrites: rewrites(store, stats),
             indexes: indexes(store, stats), timed_out_count: store.read("candidate_runs")["timed_out_count"],
             **findings(store, selection["top"]) }]
        end

        # negative-result, rewrite-rules, and burndown: what the report says beyond the candidates.
        def findings(store, top)
          { negative: top.empty? ? NegativeResult.call(store) : nil, rule_bugs: RuleBugs.call(store),
            burndown: Burndown.read(store) }
        end

        def original(store, stats)
          { original_sql: original_sql(store), original_plan: nodes(store.read("redacted_plan")["explain"], stats),
            original_measurements: store.read("baseline")["sets"].transform_values { MeasuredLabels.summary(it) } }
        end

        def rewrites(store, stats)
          context = RewriteFate.context(store)
          NegativeResult.rewrites(store).map do |name|
            entry = store.read(name)
            { "rewrite" => name, "sql" => entry["sql"], **RewriteSource.fields(entry),
              **RewriteFate.call(store, name, context), "plan" => rewrite_plan(store, name, stats),
              **checks(store, name.delete_prefix("rewrite_")) }
          end
        end

        def rewrite_plan(store, search, stats)
          plan = NegativeResult.optional(store, "index_search_#{search}")&.dig("baseline", "slow", "plan")
          plan && nodes(plan, stats)
        end

        # rewrite-test's untested atoms, and whether counterexamples had evidence on
        # them, which only a rewrite that survived counterexamples has.
        def checks(store, number)
          survived = NegativeResult.optional(store, "rewrite_survived_#{number}")
          { "untested_atoms" => NegativeResult.optional(store, "rewrite_tested_#{number}")&.fetch("untested_atoms"),
            "evidence" => (survived.fetch("evidence", true) if survived && survived["survived"] == true) }
        end

        def original_sql(store)
          clock = store.read("clock_replacements")
          replacements = clock["replacements"].map { ClockAnchoring::Replacement.new(**it.transform_keys(&:to_sym)) }
          added = clock["added_names"].map { ClockAnchoring::AddedName.new(**it.transform_keys(&:to_sym)) }
          ClockAnchoring.restore(store.read("anchored_query"), replacements, added)
        end

        def indexes(store, stats)
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          sizes = ExistingIndexes.new(store)
          store.read("index_build")["indexes"].transform_values do |built|
            proposed = IndexCandidate.from_ddl(built["ddl"], sources: [:llm])
            { "ddl" => proposed && redaction.ddl(proposed), "size" => built["size"],
              **coverage(proposed, stats, sizes) }
          end
        end

        # The existing index (from the catalog) that covers proposed as a
        # prefix, and the existing ones proposed covers.
        def coverage(proposed, stats, sizes)
          existing = existing(proposed, stats)
          covering = existing.select { |_, e| Dedupe.covers?(e, proposed) }.keys.first(1)
          redundant = existing.select { |_, e| Dedupe.covers?(proposed, e) }.keys
          covering, redundant = [covering, redundant].map { |names| names.map { sizes.named(proposed.table, it) } }
          { "covered_by" => covering.first, "makes_redundant" => redundant }
        end

        # The existing indexes on proposed's table that the catalog could
        # read, by name.
        def existing(proposed, stats)
          proposed && stats.table?(proposed.table) ? stats.table(proposed.table).indexes.compact : {}
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
