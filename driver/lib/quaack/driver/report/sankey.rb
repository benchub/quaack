# frozen_string_literal: true

require_relative "format"
require_relative "stage_style"
require_relative "sankey_stages"
require_relative "sankey_layers"
require_relative "sankey_drawing"

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, drawn: each burndown table as Sankey diagrams
      # above it, from the same stage records.
      #
      # A Sankey shows where each part came from and where it went: each
      # state is a layer (see SankeyLayers), each source in a stage's
      # "added" is its own named input, each drop reason is its own named
      # sink, and what a stage set aside for testing during ranking flows
      # into a layer of its own. Nothing widens out of nowhere.
      #
      # The units change along the way, and a diagram's widths mean one
      # unit, so each table is cut into one diagram per unit (UNITS), each
      # with a caption naming it. The cut is by stage (STAGE_UNIT): a
      # table's rows stay in order, and a diagram ends where the unit
      # changes. A diagram's last layer is what it hands on, and the next
      # diagram begins with a layer that says what the one above sent.
      #
      # SankeyDrawing does the layout and the SVG; SankeyStages builds what
      # it draws from the rows Stages gives (the same rows the table
      # draws), with the same stage sentences and words.
      module Sankey
        include SankeyStages
        include SankeyLayers

        SPINE_MAX = SankeyLayout::SPINE_MAX
        MIN_THICKNESS = SankeyLayout::MIN_THICKNESS
        STAGE_UNIT = {
          "index-rank" => :sets,
          "rewrite-rules" => :rewrites, "llm-rewrites" => :rewrites, "operator-rewrites" => :rewrites,
          "assumption-check" => :rewrites, "plan-pruning" => :rewrites, "fuzz" => :rewrites,
          "rewrite-test" => :rewrites, "counterexamples" => :rewrites,
          "rewrite-index-ideas" => :candidates, "measurement" => :candidates
        }.freeze
        # Each unit's caption. The rewrites' own index searches are added up, so they say so.
        UNITS = {
          ideas: "Unit: index ideas. Every width in this diagram counts index ideas, so widths here compare with " \
                 "each other.",
          rewrite_ideas: "Unit: index ideas, added up over every rewrite's own search. Every width in this diagram " \
                         "counts index ideas, so widths here compare with each other.",
          sets: "Unit: index sets. An idea on its own is a set of one, and each combination QUAACK tries is a set " \
                "of two or three. Every width in this diagram counts sets.",
          rewrites: "Unit: rewrites. Every width in this diagram counts rewrites.",
          candidates: "Unit: candidates. A candidate is a rewrite with the indexes chosen for it. Every width in " \
                      "this diagram counts candidates."
        }.freeze

        # Why the ranking tries as many combinations as it does (index-rank is greedy).
        COMBINATIONS = "Why this many combinations: QUAACK doesn't try every combination. It takes the " \
                       "best single index and pairs it with each of the others, then tries triples the same way, " \
                       "keeping an addition only while it lowers the cost, up to three indexes. So n ideas take " \
                       "about n - 1 pairs and up to n - 2 triples."

        # The Sankey diagrams for a table's rows, as Stages gives them, one
        # per unit, each under a caption naming its unit.
        def sankeys(id, title, rows, of_rewrite: false)
          segments = rows.slice_when { |a, b| sankey_unit(a[2]) != sankey_unit(b[2]) }.to_a
          segments.each_with_index.map do |segment, i|
            sankey_figure("sankey-#{id}-#{i + 1}", title, segment, of_rewrite, [i.positive?, i < segments.size - 1])
          end.join("\n")
        end

        private

        def sankey_unit(stage) = STAGE_UNIT.fetch(stage, :ideas)

        # One diagram under its caption. around is whether there's a diagram before it, and one after.
        def sankey_figure(key, title, segment, of_rewrite, around)
          stages = sankey_stages(segment, of_rewrite)
          layers, steps = sankey_states(stages, sankey_start(stages.first, before: around[0]), after: around[1])
          words = "#{title}, stage by stage, as a Sankey diagram. The table below has the exact numbers."
          sankey_caption(key, segment, of_rewrite) +
            SankeyDrawing.new(id: key, title: words, layers:, steps:).svg
        end

        def sankey_stages(segment, of_rewrite)
          segment.each_with_index.map { |(name, record, stage), i| sankey_stage(i, name, record, stage, of_rewrite) }
        end

        def sankey_caption(key, segment, of_rewrite)
          stage = segment.first[2]
          unit = sankey_unit(stage)
          unit = :rewrite_ideas if unit == :ideas && of_rewrite
          words = [UNITS.fetch(unit), (sankey_combinations(of_rewrite) if unit == :sets)].compact.join(" ")
          %(<p class="note unit" id="#{key}-unit">#{StageStyle.text(words)}</p>\n)
        end

        # Why the ranking tried as many combinations as it did, and for the rewrites, how many
        # each rewrite's own search tried.
        def sankey_combinations(of_rewrite)
          return COMBINATIONS unless of_rewrite

          tried = burndown["stages"].fetch("index-rank", {}).except("original")
          each = tried.map do |name, record|
            "#{Format.number(record.dig("added", "combinations").to_i)} for #{Words.rewrite(name, run_id)}"
          end
          "#{COMBINATIONS} Each rewrite has its own index search, so the count here adds them up across " \
            "#{Words.count(tried.size, "rewrite")}: #{each.join(", ")}."
        end

        # What the diagram above sent on, or what came in before the first
        # stage, when the first stage counted it.
        def sankey_start(first, before:)
          return unless first.state != :unknown && first.inn.to_i.positive?

          words = "#{before ? "Carried in from the diagram above" : "Carried in"}: #{Format.number(first.inn)}"
          SankeyParts::Layer.new(id: "start", role: :start, name: words, state: :full, total: first.inn, line: words,
                                 tip: "#{Format.number(first.inn)} came in.", sources: [], spread: false)
        end
      end
    end
  end
end
