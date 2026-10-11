# frozen_string_literal: true

require_relative "format"
require_relative "funnel"
require_relative "sankey_stages"
require_relative "sankey_layers"
require_relative "sankey_drawing"

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, drawn a second way: each burndown table as
      # Sankey diagrams beside its funnel, from the same stage records.
      #
      # The funnel keeps one width for everything in the pipe. A Sankey
      # shows where each part came from and where it went: each stage is a
      # node, what carries on from one stage to the next is a ribbon, each
      # source in a stage's "added" is its own named input, and each drop
      # reason, and what the stage held back for a real build, is its own
      # named sink. Nothing widens out of nowhere.
      #
      # The units change along the way, and a diagram's widths mean one
      # unit, so each table is cut into one diagram per unit (UNITS), each
      # with a caption naming it. The cut is by stage (STAGE_UNIT): a
      # table's rows stay in order, and a diagram ends where the unit
      # changes. The ribbon that leaves a diagram's last stage ends at a
      # node that says it went on to the diagram below, and the next
      # diagram begins with a node that says what the one above sent.
      #
      # SankeyDrawing does the layout and the SVG; SankeyStages builds what
      # it draws from the rows Stages gives (the same rows the funnel and the
      # table draw), with the same stage sentences and words.
      module Sankey
        include SankeyStages
        include SankeyLayers

        SPINE_MAX = SankeyLayout::SPINE_MAX
        MIN_THICKNESS = SankeyLayout::MIN_THICKNESS
        NOTE = "Both pictures show the same counts as the table under them: the funnel is the whole pipe at one " \
               "width, and the Sankey diagram shows where each part came from and where it went."
        STAGE_UNIT = {
          "index-rank" => :sets,
          "rewrite-rules" => :rewrites, "llm-rewrites" => :rewrites, "operator-rewrites" => :rewrites,
          "assumption-check" => :rewrites, "plan-pruning" => :rewrites, "rewrite-test" => :rewrites,
          "counterexamples" => :rewrites,
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
          stages = sankey_layers(sankey_stages(segment, of_rewrite))
          words = "#{title}, stage by stage, as a Sankey diagram. The table below has the exact numbers."
          sankey_caption(key, segment.first[2], of_rewrite) +
            SankeyDrawing.new(id: key, title: words, start: sankey_start(stages.first, before: around[0]), stages:,
                              finish: sankey_finish(stages.last, after: around[1])).svg
        end

        def sankey_stages(segment, of_rewrite)
          segment.each_with_index.map { |(name, record, stage), i| sankey_stage(i, name, record, stage, of_rewrite) }
        end

        def sankey_caption(key, stage, of_rewrite)
          unit = sankey_unit(stage)
          unit = :rewrite_ideas if unit == :ideas && of_rewrite
          %(<p class="note unit" id="#{key}-unit">#{Funnel.text(UNITS.fetch(unit))}</p>\n)
        end

        # What the diagram above sent on, or what came in before the first
        # stage, when the first stage counted it.
        def sankey_start(first, before:)
          return unless first.came_in.to_i.positive?

          sankey_edge(:start, first.inn, before ? "Carried in from the diagram above" : "Carried in",
                      "#{Format.number(first.inn)} came in.")
        end

        # What the last stage sent on, if it counted it and it isn't none.
        def sankey_finish(last, after:)
          return unless last.state == :full && last.out.positive?

          sankey_edge(:end, last.out, after ? "Went on to the diagram below" : "Went on",
                      "#{Format.number(last.out)} went on.")
        end

        def sankey_edge(kind, count, label, tip)
          SankeyLayout::Stage.new(id: kind.to_s, kind:, state: :full, inn: kind == :end ? count : 0,
                                  out: kind == :end ? nil : count, sources: [], sinks: [],
                                  line: "#{label}: #{Format.number(count)}", carry_tip: tip)
        end
      end
    end
  end
end
