# frozen_string_literal: true

require "erb"
require_relative "words"
require_relative "format"
require_relative "candidates"
require_relative "rewrites"
require_relative "indexes"
require_relative "accountability"
require_relative "stages"

module Quaack
  module Driver
    module Report
      # The template's view of one payload: the payload's fields, the
      # verdict, and the small pieces of HTML the template repeats. What a
      # label, a rewrite, an index, or a stage is in words comes from the
      # modules it includes.
      class View
        include Candidates
        include Rewrites
        include Indexes
        include Accountability
        include Stages

        TEMPLATE = File.read(File.join(__dir__, "template.html.erb"), encoding: "UTF-8").freeze
        MISSING = %(<td class="missing">#{Words::MISSING}</td>).freeze
        CACHE = "Fewer blocks read means fewer pages pulled through the cache, so less pressure on the memory " \
                "every other query shares."

        def initialize(payload, run_id, llm_calls = {})
          @payload = payload
          @run_id = run_id
          @llm_calls = llm_calls
        end

        attr_reader :run_id

        %w[top excluded infinite_sets labels rewrites indexes original_sql original_plan original_measurements
           timed_out_count].each { |field| define_method(field) { @payload.fetch(field) } }

        # DESIGN.md 15a, sent only when the selection is empty.
        def negative = @payload["negative"]

        def h(value) = Format.h(value)

        def winner = top.first

        # The verdict, a paragraph each.
        def summary
          [verdict, *(tried unless winner), *timeouts]
        end

        def verdict
          return "Nothing QUAACK tried beat #{ORIGINAL}." unless winner

          "QUAACK found something better than #{ORIGINAL}: #{Words.lower(describe(winner["label"]))}. " \
            "It #{compared}"
        end

        def tried
          "It built and measured #{Words.count(indexes.size, "index", "indexes")} and kept " \
            "#{Words.count(rewrites.size, "rewrite")}. The sections below say what became of each."
        end

        def timeouts
          runs = "#{Words.count(timed_out_count, "measurement run")} of candidates timed out, and QUAACK dropped " \
                 "those candidates."
          original = "#{ORIGINAL.capitalize} timed out on the #{list(infinite_sets.map { Words.set(it) })} values, " \
                     "so any candidate that finished there counts as better."
          [*(runs if timed_out_count.positive?), *(original unless infinite_sets.empty?)]
        end

        # The winner's blocks on the slow literal set against the original's.
        def compared
          ours = winner["slow_blocks"]
          theirs = original_measurements.dig("slow", "total_blocks")
          read = "read #{Format.number(ours)} blocks on the slow values,"
          return "#{read} where #{ORIGINAL} timed out." unless theirs

          "#{read} against #{Format.number(theirs)} for #{ORIGINAL} (#{Format.fewer(ours, theirs)}% fewer)."
        end

        # The stored rewrite a label ran, or nil for the original query.
        def rewrite_of(label) = rewrites.find { it["rewrite"] == label.to_s.split(":").first }

        def anchor(rewrite) = rewrite.to_s.tr("_", "-")

        def node(node)
          text = node["node"].to_s
          text += " on #{node["relation"]}" if node["relation"]
          text += " using #{node["index"]}" if node["index"]
          rows = Words.count(node["actual_rows"] || node["est_rows"], "row")
          "#{text} (#{[rows, share(node["selectivity"])].compact.join(", ")})"
        end

        # A selectivity as a share of the table, or nil if there's none.
        def share(selectivity)
          return unless selectivity
          return "under 0.1% of the table" if selectivity.positive? && selectivity < 0.0005

          format("%.1f%% of the table", selectivity * 100)
        end

        def sql(text) = %(<pre class="sql"><code>#{h Format.sql(text)}</code></pre>)

        def code(text) = "<code>#{h text}</code>"

        def num(value) = %(<td class="num">#{h(value.is_a?(Integer) ? Format.number(value) : value)}</td>)

        # A count, or "not recorded" for one the payload doesn't carry.
        def count_cell(count) = count.nil? ? MISSING : num(count)

        # A burndown row's cells: its record's counts, or "not recorded".
        def stage_cells(record, stage)
          return %(<td colspan="6" class="missing">#{Words::MISSING}</td>) unless record

          [num(record["in"]), "<td>#{h breakdown(record["added"], rules: stage == "6c")}</td>",
           "<td>#{h breakdown(record["dropped"])}</td>", num(record["set_aside"]), num(record["out"]),
           "<td>#{h breakdown(record["extra"])}</td>"].join
        end

        # A built index's row: its DDL, its size, the existing index that
        # covers it, and the existing ones it makes redundant, with sizes.
        def built_row(name)
          index = indexes.fetch(name)
          ddl = index["ddl"] ? code(index["ddl"]) : h("#{name} (QUAACK couldn't read this index's definition back)")
          "<tr><td>#{ddl}</td>#{num(Format.size(index["size"]))}<td>#{overlap([index["covered_by"]].compact)}</td>" \
            "<td>#{overlap(index["makes_redundant"])}</td></tr>"
        end

        def overlap(existing) = existing.empty? ? "none" : existing.map { h existing(it) }.join("<br>")

        def render = ERB.new(TEMPLATE, trim_mode: "<>").result(binding)
      end
    end
  end
end
