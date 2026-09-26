# frozen_string_literal: true

require "erb"

module Quaack
  module Driver
    # README step 15: the main report, as HTML, from the enclave's report
    # message (`quaacks report-payload`). The explanation is templated from
    # the measurements, plan node shapes, and selectivities, never written
    # by an LLM. Every value is HTML-escaped.
    #
    #   Report.render(payload, run_id:)  # => HTML String
    #   Report.write(payload, run_id:, path:)  # => path
    #
    # The negative-result (15a) and burndown (15b) sections are left as
    # placeholders for their own tasks.
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
        <% indexes.each do |name, i| %><tr><td><%= h name %></td><td><%= h i["ddl"] %></td><td><%= size(i["size"]) %></td><td><%= h i["covered_by"] %></td><td><%= h i["makes_redundant"].join(", ") %></td></tr>
        <% end %></table></section>
        <section id="negative-result"></section>
        <section id="burndown"></section>
        </body></html>
      HTML

      # The template's view of one payload.
      class View
        def initialize(payload, run_id)
          @payload = payload
          @run_id = run_id
        end

        attr_reader :run_id

        %w[top excluded infinite_sets verdicts measurements candidates indexes original_plan
           timed_out_count].each { |field| define_method(field) { @payload.fetch(field) } }

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

      def render(payload, run_id:) = View.new(payload, run_id).render

      def write(payload, run_id:, path:)
        File.write(path, render(payload, run_id:))
        path
      end
    end
  end
end
