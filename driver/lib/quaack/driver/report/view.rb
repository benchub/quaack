# frozen_string_literal: true

require "erb"
require_relative "words"
require_relative "format"
require_relative "index_ddl"
require_relative "candidates"
require_relative "kinds"
require_relative "verdict"
require_relative "rewrites"
require_relative "not_better_fate"
require_relative "rule_links"
require_relative "indexes"
require_relative "accountability"
require_relative "plans"
require_relative "stages"
require_relative "funnel"
require_relative "providers"
require_relative "usage"
require_relative "failed_branches"
require_relative "cautions"

module Quaack
  module Driver
    module Report
      # The template's view of one payload: the payload's fields, the
      # verdict, and the small pieces of HTML the template repeats. What a
      # label, a rewrite, an index, or a stage is in words comes from the
      # modules it includes.
      class View
        include Candidates
        include NotBetterFate
        include Kinds
        include Verdict
        include Rewrites
        include RuleLinks
        include Indexes
        include Accountability
        include Plans
        include Stages
        include Funnel
        include Providers
        include Usage
        include FailedBranches
        include Cautions

        TEMPLATE = File.read(File.join(__dir__, "template.html.erb"), encoding: "UTF-8").freeze
        MISSING = %(<td class="missing">#{Words::MISSING}</td>).freeze
        CACHE = "Fewer blocks read means fewer pages pulled through the cache, so less pressure on the memory " \
                "every other query shares."
        # Why the winner's plan has no blocks: the payload has no measured
        # plan for it. It names no cause, so it stays true whatever left the
        # plan out, such as a run measured before the enclave kept one.
        NO_MEASURED_PLAN = "QUAACK has no measured plan for the winner, so the blocks it read at each step " \
                           "aren't recorded."
        ESTIMATED_PLAN = "The plan below is the one Postgres expected, from EXPLAIN without running the query, " \
                         "which counts no blocks."

        # llm is the driver's own: "record", the run's provenance record,
        # and "calls", each provider's calls by step (Providers).
        def initialize(payload, run_id, llm_calls = {}, llm = {})
          @payload = Format.unmarked(payload)
          @run_id = Format.unmarked(run_id)
          @llm_calls = Format.unmarked(llm_calls)
          @llm = Format.unmarked(llm)
        end

        attr_reader :run_id

        %w[top excluded infinite_sets labels rewrites indexes original_sql original_plan original_measurements
           timed_out_count].each { |field| define_method(field) { @payload.fetch(field) } }

        # DESIGN.md's negative-result, whether or not top is empty.
        def negative = @payload["negative"]

        def h(value) = Format.h(value)

        def winner = top.first

        def tried
          "It built and measured #{Words.count(indexes.size, "index", "indexes")} and kept " \
            "#{Words.count(rewrites.size, "rewrite")}. The sections below say what became of each."
        end

        # DESIGN.md's statistics: what the production role couldn't see,
        # which the run went on without. An older payload has none.
        def hidden_statistics
          hidden = @payload["hidden_statistics"] or return
          extended = hidden["extended_statistics"]
          parts = [*(Words.count(extended, "extended statistics object") if extended.positive?),
                   *hidden_indexes(hidden["indexes"])]
          return if parts.empty?

          "Your role on the production server couldn't see the statistics of #{parts.join(" and of ")}, so " \
            "QUAACK's estimates for those may be off. A role that owns the tables can see them."
        end

        def hidden_indexes(names)
          return [] if names.empty?

          ["#{names.size == 1 ? "this expression index" : "these expression indexes"}: " \
           "#{names.map { Format.sql_span(it) }.join(", ")}"]
        end

        # The winner's blocks on the slow literal set against the original's.
        def compared
          ours = winner["slow_blocks"]
          theirs = original_measurements.dig("slow", "total_blocks")
          read = "read #{Format.number(ours)} blocks on the slow values,"
          return "#{read} where #{ORIGINAL} timed out." unless theirs

          "#{read} against #{Format.number(theirs)} for #{ORIGINAL} (#{Format.apart(ours, theirs)}% fewer)."
        end

        # The stored rewrite a label ran, or nil for the original query.
        def rewrite_of(label) = rewrites.find { it["rewrite"] == label.to_s.split(":").first }

        def anchor(rewrite) = rewrite.to_s.tr("_", "-")

        def sql(text) = %(<pre class="sql"><code>#{h Format.sql(text)}</code></pre>)

        def sql_code(text) = h(Format.sql_span(text))

        # A wait in seconds: "12.3 s", or "1 min 1.5 s" from a minute on.
        def wait(seconds)
          minutes, rest = seconds.divmod(60)
          minutes.zero? ? Format.decimal(rest, "s") : "#{Format.number(minutes.to_i)} min #{Format.decimal(rest, "s")}"
        end

        def num(value) = %(<td class="num">#{h(value.is_a?(Integer) ? Format.number(value) : value)}</td>)

        # A count, or "not recorded" for one the payload doesn't carry.
        def count_cell(count) = count.nil? ? MISSING : num(count)

        # A burndown row's cells: its record's counts, or "not recorded".
        def stage_cells(record, stage)
          return %(<td colspan="6" class="missing">#{Words::MISSING}</td>) unless record

          [num(record["in"]), "<td>#{h breakdown(record["added"], rules: stage == "rewrite-rules")}</td>",
           "<td>#{h breakdown(record["dropped"], stage:)}</td>", num(record["set_aside"]), count_cell(record["out"]),
           "<td>#{h breakdown(record["extra"])}</td>"].join
        end

        # A built index's row: its DDL, its size, the existing index that
        # covers it, and the existing ones it makes redundant, with sizes.
        def built_row(name)
          index = indexes.fetch(name)
          unread = "#{Format.sql_span(name)} (QUAACK couldn't read this index's definition back)"
          ddl = index["ddl"] ? sql_code(index["ddl"]) : h(unread)
          "<tr><td>#{ddl}</td>#{num(Format.size(index["size"]))}<td>#{overlap([index["covered_by"]].compact)}</td>" \
            "<td>#{overlap(index["makes_redundant"])}</td></tr>"
        end

        def overlap(existing) = existing.empty? ? "none" : existing.map { h existing(it) }.join("<br>")

        def render = ERB.new(TEMPLATE, trim_mode: "<>").result(binding)
      end
    end
  end
end
