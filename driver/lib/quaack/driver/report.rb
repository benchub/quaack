# frozen_string_literal: true

require "erb"

module Quaack
  module Driver
    # DESIGN.md step 15: the main report, as HTML, from the enclave's report
    # message (`quaacks report-payload`). The explanation is templated from
    # the measurements, plan node shapes, and selectivities, never written
    # by an LLM. Every value is HTML-escaped.
    #
    #   Report.render(payload, run_id:)  # => HTML String
    #   Report.write(payload, run_id:, path:)  # => path
    #
    # The negative-result section (15a) is filled only when the payload
    # carries negative, which the enclave sends when the selection is empty.
    # The burndown section (15b) renders the payload's burndown counts, plus
    # llm_calls, the driver's own Burndown#llm_calls.
    #
    #   Report.render(payload, run_id:, llm_calls: burndown.llm_calls)
    module Report
      TEMPLATE = <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>QUAACK report <%= h run_id %></title>
        <style>body{font-family:sans-serif;margin:2em}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:2px 6px}pre{background:#f4f4f4;padding:6px}</style>
        </head><body>
        <h1>QUAACK report <%= h run_id %></h1>
        <section id="ranking"><h2>Overall ranking</h2>
        <table><tr><th>#</th><th>Candidate</th><th>Slow blocks</th><th>Sum across literals</th><th>Index footprint</th></tr>
        <% top.each_with_index do |t, i| %><tr class="rank"><td><%= i + 1 %></td><td><%= h t["label"] %></td><td><%= t["slow_blocks"] %></td><td><%= t["total_blocks_sum"] %></td><td><%= size(t["footprint"]) %></td></tr>
        <% end %></table>
        <% unless excluded.empty? %><p>Excluded:</p><ul><% excluded.each do |label, why| %><li><%= h label %>: <%= h why %></li><% end %></ul><% end %>
        <p><%= timed_out_count %> candidate runs timed out and were dropped.</p>
        <% unless infinite_sets.empty? %><p>The original timed out on: <%= h infinite_sets.join(", ") %>.</p><% end %>
        </section>
        <section id="explanation"><h2>Why the winner reads fewer blocks</h2>
        <% if winner %><p><%= h explanation %></p>
        <p>Original plan:</p><ul><% original_plan.each do |n| %><li><%= h node(n) %></li><% end %></ul>
        <% if winner["plan"] %><p>Winner's plan:</p><ul><% winner["plan"].each do |n| %><li><%= h node(n) %></li><% end %></ul><% end %>
        <% else %><p>No candidate beat the original.</p><% end %>
        </section>
        <% candidates.each do |c| %><section class="candidate"><h2><%= h c["label"] %></h2>
        <pre><%= h c["sql"] %></pre>
        <table><tr><th>Literal set</th><th>Blocks</th><th>Hit</th><th>Read</th><th>Verdict</th><th>Stability</th></tr>
        <% (measurements[c["label"]] || {}).each do |set, s| %><tr><td><%= h set %></td><td><%= s["timed_out"] ? "timed out" : s["total_blocks"] %></td><td><%= s["hit"] %></td><td><%= s["read"] %></td><td><%= h verdicts.dig(c["label"], set) %></td><td><%= s["stable"] == false ? "unstable" : "" %></td></tr>
        <% end %></table>
        <% if c["untested_atoms"] %><p>Untested atoms<%= c["evidence"] == false ? " (no counterexample round loaded its inserts, so step 10 gave no evidence)" : " (step 10's rounds exercised them)" %>:</p>
        <ul><% c["untested_atoms"].each do |a| %><li><%= h(a.is_a?(Hash) ? a.values.join(" ") : a) %></li><% end %></ul><% end %>
        <% unless c["indexes"].empty? %><p>Indexes: <%= h c["indexes"].join(", ") %></p><% end %>
        </section>
        <% end %>
        <section id="indexes"><h2>Proposed indexes</h2>
        <table><tr><th>Name</th><th>DDL</th><th>Built size</th><th>Existing index covering it</th><th>Existing indexes it makes redundant</th></tr>
        <% indexes.each do |name, i| %><tr><td><%= h name %></td><td><%= h(i["ddl"] || "(the enclave could not parse this DDL)") %></td><td><%= size(i["size"]) %></td><td><%= h i["covered_by"] %></td><td><%= h i["makes_redundant"].join(", ") %></td></tr>
        <% end %></table></section>
        <section id="negative-result"><% if negative %><h2>Why nothing beat the original</h2>
        <p>Rewrites disproved:</p><ul><% negative["disproved"].each do |d| %><li><%= h disproof(d) %></li><% end %></ul>
        <p>Indexes the planner declined:</p><ul><% negative["declined"].each do |d| %><li><%= h d["search"] %>: <%= h d["ddl"] %>: <%= h declined(d) %></li><% end %></ul>
        <p>Proposed indexes that already existed:</p><ul><% negative["existing"].each do |e| %><li><%= h e["search"] %>: <%= h e["ddl"] %>: already covered by <%= h e["covered_by"] %></li><% end %></ul>
        <p>Rewrites that passed steps 9 and 10 but were knocked out:</p><ul><% negative.fetch("knocked_out", []).each do |k| %><li><%= h k["label"] %>: passed steps 9 and 10, but <%= h knocked_out(k["reason"]) %></li><% end %></ul>
        <% end %></section>
        <section id="burndown"><h2>Burndown</h2>
        <% [["index", "Index candidates for the original query", index_rows], ["rewrite", "Rewrite candidates", rewrite_rows]].each do |id, title, rows| %><h3><%= h title %></h3>
        <table id="burndown-<%= id %>"><tr><th>Stage</th><th>In</th><th>Added</th><th>Dropped</th><th>Set aside</th><th>Out</th><th>Other counts</th></tr>
        <% rows.each do |label, r| %><tr><td><%= h label %></td><td><%= h r["in"] %></td><td><%= h counts(r["added"]) %></td><td><%= h counts(r["dropped"]) %></td><td><%= h r["set_aside"] %></td><td><%= h r["out"] %></td><td><%= h counts(r["extra"]) %></td></tr>
        <% end %></table>
        <% end %><h3>Work totals</h3>
        <ul id="burndown-totals"><% @llm_calls.each do |step, n| %><li>LLM calls, <%= h step %>: <%= n.to_i %></li><% end %><% burndown["totals"].each do |name, n| %><li><%= h name %>: <%= n.to_i %></li><% end %></ul>
        </section>
        </body></html>
      HTML

      # The template's view of one payload.
      class View
        def initialize(payload, run_id, llm_calls = {})
          @payload = payload
          @run_id = run_id
          @llm_calls = llm_calls
        end

        attr_reader :run_id

        %w[top excluded infinite_sets verdicts measurements candidates indexes original_plan
           timed_out_count].each { |field| define_method(field) { @payload.fetch(field) } }

        INDEX_STAGES = %w[5a-1 5a-2 5a-3 5a-4 5a-5 5a-6 5a-7].freeze
        REWRITE_STAGES = %w[6a step7 6b step8 step9 step10].freeze

        # DESIGN.md 15b: the recorded counts, { "stages", "totals" }.
        def burndown = @payload["burndown"] || { "stages" => {}, "totals" => {} }

        # The original query's index search, one row per stage.
        def index_rows
          INDEX_STAGES.filter_map { |stage| (r = burndown["stages"].dig(stage, "original")) && [stage, r] }
        end

        # The rewrite stages, each summed over its searches, then the
        # rewrites' own index searches (steps 8 and 11) totaled per stage.
        def rewrite_rows
          searches = INDEX_STAGES.filter_map do |stage|
            records = burndown["stages"].fetch(stage, {}).except("original").values
            ["Steps 8 and 11: #{stage}", sum(records)] unless records.empty?
          end
          summed(REWRITE_STAGES) + searches + summed(%w[step11 step14])
        end

        def summed(stages)
          stages.filter_map { |stage| (records = burndown["stages"][stage]) && [stage, sum(records.values)] }
        end

        def sum(records)
          records.reduce do |a, b|
            a.merge(b) { |_, x, y| x.is_a?(Hash) ? x.merge(y) { |_, m, n| m + n } : x + y }
          end
        end

        def counts(hash) = hash.map { |name, n| "#{name}: #{n}" }.join(", ")

        # DESIGN.md 15a, sent only when the selection is empty.
        def negative = @payload["negative"]

        KNOCKED_OUT = { "not_better" => "minimax found it not better than the original",
                        "footprint_tie" => "minimax dropped it for tying a candidate with a smaller index footprint",
                        "result_mismatch" => "its results didn't match the original's in 14c" }.freeze

        def knocked_out(reason) = KNOCKED_OUT.fetch(reason) { "14d excluded it (#{reason})" }

        def disproof(entry)
          if entry["step"] == "step10"
            round = ", counterexample round #{entry["round"]}" if entry["round"]
            return "#{entry["rewrite"]}: disproved in step 10#{round}"
          end

          "#{entry["rewrite"]}: disproved in step 9 by scenario #{entry["scenario"]} (rule #{entry["rule"]})"
        end

        def declined(entry)
          return "the planner never used it" if entry["reason"] == "unused"
          return "HypoPG refused it (SQLSTATE #{entry["sqlstate"]})" if entry["reason"] == "hypopg_refused"

          "refused (#{entry["reason"]})"
        end

        def h(value) = ERB::Util.html_escape(value.to_s)

        def winner = candidates.find { it["label"] == top.first&.fetch("label") }

        def size(bytes) = bytes.nil? ? "" : "#{bytes / 1024} kB"

        def explanation
          label = winner["label"]
          ours = measurements.dig(label, "slow", "total_blocks")
          theirs = measurements.dig("original", "slow", "total_blocks")
          "#{label} reads #{ours} blocks on the slow literal set, #{versus(ours, theirs)}."
        end

        def versus(ours, theirs)
          return "where the original timed out" unless theirs

          "against #{theirs} for the original (#{((theirs - ours) * 100.0 / theirs).round}% fewer)"
        end

        def node(node)
          text = node["node"].to_s
          text += " on #{node["relation"]}" if node["relation"]
          text += " using #{node["index"]}" if node["index"]
          rows = node["actual_rows"] || node["est_rows"]
          details = ["#{rows} rows", node["selectivity"] && format("selectivity %.1f%%", node["selectivity"] * 100)]
          "#{text} (#{details.compact.join(", ")})"
        end

        def render = ERB.new(TEMPLATE, trim_mode: "<>").result(binding)
      end

      module_function

      def render(payload, run_id:, llm_calls: {}) = View.new(payload, run_id, llm_calls).render

      def write(payload, run_id:, path:, llm_calls: {})
        File.write(path, render(payload, run_id:, llm_calls:))
        path
      end
    end
  end
end
