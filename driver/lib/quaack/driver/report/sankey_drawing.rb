# frozen_string_literal: true

require "erb"
require_relative "format"
require_relative "sankey_layout"
require_relative "sankey_paths"
require_relative "sankey_labels"

module Quaack
  module Driver
    module Report
      # One Sankey diagram as an inline SVG: ribbons, then the layers and the
      # sources' and sinks' nodes, then the words (see SankeyLayout for where they
      # go, and SankeyLayers for what is drawn). Every node and ribbon has a hover,
      # and carries its count and the nodes it joins in data attributes.
      #
      # A layer the run didn't count is grey and dashed, and so are the ribbons
      # into or out of it. A carry whose two ends differ in width (a count that
      # doesn't join up) tapers.
      # Each method here works out several x and y ends at once.
      # rubocop:disable-next Metrics/AbcSize
      class SankeyDrawing
        include SankeyLabels

        Layout = SankeyLayout
        NODE_WIDTH = 8.0
        GREY = 'style="fill: var(--uncounted-fill); stroke: var(--uncounted-stroke)" stroke-dasharray="4 3"'
        # A source that added nothing: an empty box, and an empty line into its layer.
        EMPTY = 'style="fill: none; stroke: var(--sk-source)"'
        KIND_COLOR = { source: "var(--sk-source)", drop: "var(--sk-drop)", held: "var(--sk-held)" }.freeze
        Ribbon = Struct.new(:kind, :path, :from, :to, :amount, :tip, :style)

        def initialize(id:, title:, layers:, steps:)
          @id = id
          @title = title
          @layout = Layout.new(layers:, steps:)
        end

        def svg
          height = @layout.place
          drawn = [*carry_ribbons, *source_ribbons, *sink_ribbons, *aside_ribbons, *bars, *words]
          %(<svg id="#{@id}" class="sankey" role="img" aria-labelledby="#{@id}-title" ) +
            %(viewBox="0 0 #{VIEW_WIDTH} #{height}"><title id="#{@id}-title">#{text(@title)}</title>#{drawn.join}</svg>)
        end

        private

        def layers = @layout.layers

        def steps = @layout.steps

        def title(tip) = tip.to_s.empty? ? "" : "<title>#{text(tip)}</title>"

        def paint(color, opacity = 0.4) = %(style="fill: #{color}; stroke: #{color}" fill-opacity="#{opacity}")

        def color_of(layer) = layer.color || KIND_COLOR[layer.role == :held ? :held : :source]

        def carry_ribbons
          steps.select(&:carry).map do |step|
            carry = step.carry
            path = SankeyPaths.carry(step.from.bottom, step.into.y, carry.from_edge, carry.into_edge)
            ribbon_tag(Ribbon.new(step.grey ? "carry unknown" : "carry", path, step.from.id, step.into.id,
                                  carry.amount, step.carry_tip, step.grey ? GREY : paint(color_of(step.from))))
          end
        end

        # Each source's ribbon into its layer. A zero's is an empty line from the middle of its box.
        def source_ribbons
          layers.flat_map do |layer|
            layer.above.map do |source|
              flow = source.flow
              zero = flow.amount.zero?
              from = zero ? [source.bar_x + (source.thickness / 2)] * 2 : source.bar_edge
              path = SankeyPaths.carry(source.bar_y + SankeyLanes::FLAT, layer.y, from, source.edge)
              ribbon_tag(Ribbon.new(zero ? "source zero" : "source", path, source.id, layer.id, flow.amount, flow.tip,
                                    zero ? EMPTY : paint(color_of(layer))))
            end
          end
        end

        def sink_ribbons
          steps.flat_map do |step|
            step.below.map do |placed|
              path = SankeyPaths.sink(placed.edge, step.from.bottom, Layout::NODE_X, *placed.span)
              flow = placed.flow
              ribbon_tag(Ribbon.new(flow.kind, path, step.from.id, placed.id, flow.amount, flow.tip,
                                    paint(KIND_COLOR.fetch(flow.kind), 0.35)))
            end
          end
        end

        def aside_ribbons
          held = layers.find { it.role == :held } or return []
          steps.flat_map do |step|
            step.aside.map do |aside|
              path = SankeyPaths.aside(aside.edge, step.from.bottom, aside.column, aside.turn, held.y)
              flow = aside.flow
              ribbon_tag(Ribbon.new("held", path, step.from.id, held.id, flow.amount, flow.tip,
                                    paint(KIND_COLOR[:held], 0.35)))
            end
          end
        end

        def ribbon_tag(ribbon)
          attributes = { class: "ribbon #{ribbon.kind}", "data-from": ribbon.from, "data-to": ribbon.to,
                         "data-count": ribbon.amount, d: ribbon.path }
          %(<path #{attrs(attributes)} #{ribbon.style}>#{title(ribbon.tip)}</path>)
        end

        def attrs(pairs) = pairs.compact.map { |name, value| %(#{name}="#{value}") }.join(" ")

        def bars
          [*layers.map { layer_bar(it) }, *layers.flat_map { |layer| layer.above.map { source_bar(layer, it) } },
           *steps.flat_map { |step| step.below.map { flow_bar(step, it) } }]
        end

        def layer_bar(layer)
          %(<rect #{attrs(layer_attributes(layer))} #{layer.grey? ? GREY : paint(color_of(layer), 0.85)}>) +
            %(#{title(layer.tip)}</rect>)
        end

        def layer_attributes(layer)
          { class: ["node layer", layer.role, (layer.state unless layer.state == :full)].compact.join(" "),
            "data-id": layer.id, "data-stage": (text(layer.name) if layer.name), "data-count": layer.total,
            x: layer.x, y: layer.y, width: layer.width.round(2), height: SankeyParts::BAR_HEIGHT }
        end

        # A source's flat bar, as wide as its count, or an empty box for none.
        def source_bar(layer, source)
          flow = source.flow
          zero = flow.amount.zero?
          attributes = { class: zero ? "node source zero" : "node source", "data-id": source.id,
                         "data-stage": text(layer.name), "data-count": flow.amount, x: source.bar_x.round(2),
                         y: source.bar_y, width: source.thickness.round(2), height: SankeyLanes::FLAT }
          %(<rect #{attrs(attributes)} #{zero ? EMPTY : %(style="fill: #{KIND_COLOR[:source]}")}>) +
            %(#{title(flow.tip)}</rect>)
        end

        # A drop's node, in the column to the right of the step it belongs to.
        def flow_bar(step, placed)
          flow = placed.flow
          attributes = { class: "node #{flow.kind}", "data-id": placed.id, "data-stage": text(step.into.name),
                         "data-count": flow.amount, x: Layout::NODE_X, y: placed.upper.round(2),
                         width: NODE_WIDTH, height: placed.thickness.round(2) }
          %(<rect #{attrs(attributes)} style="fill: #{KIND_COLOR.fetch(flow.kind)}">#{title(flow.tip)}</rect>)
        end
      end
    end
  end
end
