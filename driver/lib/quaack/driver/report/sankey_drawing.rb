# frozen_string_literal: true

require "erb"
require_relative "format"
require_relative "sankey_layout"
require_relative "sankey_paths"

module Quaack
  module Driver
    module Report
      # One Sankey diagram as an inline SVG: ribbons, then the nodes, then
      # the words (see SankeyLayout for where they go, and Sankey for what
      # is drawn). Every node and ribbon has a hover, and carries its count and
      # the nodes it joins in data attributes. All the words sit in one column,
      # at TEXT_X, so none can run into a ribbon.
      #
      # A stage the run didn't record is a grey, dashed node, and the ribbons
      # into or out of it are grey and dashed too. So is a stage that counted
      # only what came in, but its way in is drawn as counted. A ribbon whose
      # two ends differ in width (a count that doesn't join up) tapers.
      class SankeyDrawing
        Layout = SankeyLayout
        VIEW_WIDTH = 940
        NODE_WIDTH = 8.0
        TEXT_X = 314
        LABEL_MAX = 88
        GREY = 'style="fill: var(--uncounted-fill); stroke: var(--uncounted-stroke)" stroke-dasharray="4 3"'
        KIND_COLOR = { source: "var(--sk-source)", drop: "var(--sk-drop)", held: "var(--sk-held)" }.freeze
        Ribbon = Struct.new(:kind, :path, :from, :to, :amount, :tip, :style)

        def initialize(id:, title:, start:, stages:, finish:)
          @id = id
          @title = title
          @layout = Layout.new(start:, stages:, finish:)
        end

        def svg
          height = @layout.place
          drawn = [*carry_ribbons, *flow_ribbons, *bars, *words]
          %(<svg id="#{@id}" class="sankey" role="img" aria-labelledby="#{@id}-title" ) +
            %(viewBox="0 0 #{VIEW_WIDTH} #{height}"><title id="#{@id}-title">#{text(@title)}</title>#{drawn.join}</svg>)
        end

        private

        def nodes = @layout.nodes

        def text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))

        def title(tip) = tip.to_s.empty? ? "" : "<title>#{text(tip)}</title>"

        def paint(color, opacity = 0.4) = %(style="fill: #{color}; stroke: #{color}" fill-opacity="#{opacity}")

        def carry_ribbons = @layout.carries.compact.map { carry_ribbon(it) }

        def carry_ribbon(carry)
          from = carry.from
          path = SankeyPaths.carry(from.bottom, carry.into.y, carry.from_edge, carry.into_edge)
          ribbon_tag(Ribbon.new(carry.kind, path, from.id, carry.into.id, carry.amount, from.carry_tip,
                                carry_style(carry)))
        end

        def carry_style(carry) = carry.grey ? GREY : paint(color_of(carry.from))

        def color_of(node) = node.color || KIND_COLOR[:source]

        def flow_ribbons
          nodes.flat_map do |node|
            node.above.map { source_ribbon(node, it) } + node.below.map { sink_ribbon(node, it) }
          end
        end

        def source_ribbon(node, placed)
          path = SankeyPaths.source(placed.edge, node.y, Layout::NODE_X, *placed.span)
          flow = placed.flow
          ribbon_tag(Ribbon.new("source", path, placed.id, node.id, flow.amount, flow.tip, paint(color_of(node))))
        end

        def sink_ribbon(node, placed)
          path = SankeyPaths.sink(placed.edge, node.bottom, Layout::NODE_X, *placed.span)
          flow = placed.flow
          ribbon_tag(Ribbon.new(flow.kind, path, node.id, placed.id, flow.amount, flow.tip,
                                paint(KIND_COLOR.fetch(flow.kind), 0.35)))
        end

        def ribbon_tag(ribbon)
          attributes = { class: "ribbon #{ribbon.kind}", "data-from": ribbon.from, "data-to": ribbon.to,
                         "data-count": ribbon.amount, d: ribbon.path }
          %(<path #{attrs(attributes)} #{ribbon.style}>#{title(ribbon.tip)}</path>)
        end

        def attrs(pairs) = pairs.compact.map { |name, value| %(#{name}="#{value}") }.join(" ")

        def bars
          nodes.flat_map { |node| [stage_bar(node), *(node.above + node.below).map { flow_bar(node, it) }] }
        end

        def stage_bar(node)
          grey = node.kind == :stage && node.state != :full
          %(<rect #{attrs(bar_attributes(node))} #{grey ? GREY : paint(color_of(node), 0.85)}>) +
            %(#{title(bar_tip(node))}</rect>)
        end

        def bar_attributes(node)
          { class: bar_class(node), "data-id": node.id, "data-stage": (text(node.name) if node.name),
            "data-count": counted(node), x: Layout::LEFT, y: node.y, width: node.width.round(2), height: node.height }
        end

        def bar_class(node)
          ["node", node.kind, (node.state if node.kind == :stage && node.state != :full)].compact.join(" ")
        end

        def bar_tip(node) = node.kind == :stage ? node.tip : node.carry_tip

        # What a node counted going on, or nil if it didn't count it.
        def counted(node) = node.kind == :end ? node.came_in : node.went_on

        # A source's or sink's node, in the column beside the stage it belongs to.
        def flow_bar(node, placed)
          flow = placed.flow
          attributes = { class: "node #{flow.kind}", "data-id": placed.id, "data-stage": text(node.name),
                         "data-count": flow.amount, x: Layout::NODE_X, y: placed.upper.round(2),
                         width: NODE_WIDTH, height: placed.thickness.round(2) }
          %(<rect #{attrs(attributes)} style="fill: #{KIND_COLOR.fetch(flow.kind)}">#{title(flow.tip)}</rect>)
        end

        def words
          nodes.flat_map do |node|
            [*stage_words(node), *(node.above + node.below).map { line("flow", it.centre + 4, it.flow.label) }]
          end
        end

        def stage_words(node)
          return [line("flow", node.y + 15, node.line)] unless node.kind == :stage

          [line("stage", node.y + 15, node.name), line("counts", node.y + 31, node.line)]
        end

        def line(kind, height, words)
          shown = words.length > LABEL_MAX ? "#{words[0, LABEL_MAX - 1]}…" : words
          %(<text class="#{kind}" x="#{TEXT_X}" y="#{height.round(2)}">#{text(shown)}</text>)
        end
      end
    end
  end
end
