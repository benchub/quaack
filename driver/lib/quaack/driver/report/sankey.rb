# frozen_string_literal: true

require_relative "format"
require_relative "stage_style"
require_relative "sankey_stages"
require_relative "sankey_layers"
require_relative "sankey_drawing"

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, drawn: each burndown table as a Sankey diagram
      # above it, from the same stage records.
      #
      # A Sankey shows where each part came from and where it went: each
      # state is a layer (see SankeyLayers), each source in a stage's
      # "added" is its own named input, each drop reason is its own named
      # sink, and what a stage set aside for testing during ranking flows
      # into a layer of its own. Nothing widens out of nowhere.
      #
      # The units change along the way (STAGE_UNIT), so where they do, a
      # dashed line spans the diagram, labelled with the unit above it and
      # the one below (SankeyLayerWords::UNITS). The last layer above the line flows
      # straight into the first below it, and the widths share one scale.
      # Why the ranking tried as many combinations as it did is in a note
      # under the diagram and in the ranking's hover.
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
          "enumerate" => :rewrites,
          "rewrite-test" => :rewrites, "counterexamples" => :rewrites,
          "rewrite-index-ideas" => :candidates, "measurement" => :candidates
        }.freeze
        # Why the ranking tries as many combinations as it does (index-rank is greedy).
        COMBINATIONS = "Why this many combinations: QUAACK doesn't try every combination. It takes the " \
                       "best single index and pairs it with each of the others, then tries triples the same way, " \
                       "keeping an addition only while it lowers the cost, up to three indices. So n ideas take " \
                       "about n - 1 pairs and up to n - 2 triples."

        # The Sankey diagram for a table's rows, as Stages gives them, with a dashed line
        # where the unit changes, then a note on the ranking's combinations if it ranked.
        def sankeys(id, title, rows, of_rewrite: false)
          key = "sankey-#{id}"
          stages = sankey_stages(rows, of_rewrite)
          stages.zip(rows) { |stage, row| stage.unit = sankey_unit(row[2]) }
          layers, steps = sankey_states(stages, sankey_start(stages.first))
          words = "#{title}, stage by stage, as a Sankey diagram. The table below has the exact numbers."
          SankeyDrawing.new(id: key, title: words, layers:, steps:).svg + sankey_note(key, stages, of_rewrite)
        end

        private

        def sankey_unit(stage) = STAGE_UNIT.fetch(stage, :ideas)

        def sankey_stages(rows, of_rewrite)
          rows.each_with_index.map { |(name, record, stage), i| sankey_stage(i, name, record, stage, of_rewrite) }
        end

        # The note under the diagram: why the ranking tried as many combinations as it did.
        def sankey_note(key, stages, of_rewrite)
          return "" unless stages.any? { it.unit == :sets }

          %(\n<p class="note" id="#{key}-note">#{StageStyle.text(sankey_combinations(of_rewrite))}</p>)
        end

        # Why the ranking tried as many combinations as it did, and for the rewrites, how many
        # each rewrite's own search tried.
        def sankey_combinations(of_rewrite)
          of_rewrite ? "#{COMBINATIONS} #{sankey_each_rewrite}" : COMBINATIONS
        end

        # How many combinations each rewrite's own search tried, for the rewrites' ranking.
        def sankey_each_rewrite
          tried = burndown["stages"].fetch("index-rank", {}).except("original")
          each = tried.map do |name, record|
            "#{Format.number(record.dig("added", "combinations").to_i)} for #{Words.rewrite(name, run_id)}"
          end
          "Each rewrite has its own index search, so the count here adds them up across " \
            "#{Words.count(tried.size, "rewrite")}: #{each.join(", ")}."
        end

        # What came in before the first stage, when the first stage counted it.
        def sankey_start(first)
          return unless first.state != :unknown && first.inn.to_i.positive?

          words = "Carried in: #{Format.number(first.inn)}"
          SankeyParts::Layer.new(id: "start", role: :start, name: words, state: :full, total: first.inn, line: words,
                                 tip: "#{Format.number(first.inn)} came in.", sources: [], spread: false)
        end
      end
    end
  end
end
