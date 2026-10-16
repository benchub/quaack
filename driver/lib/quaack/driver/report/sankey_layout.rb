# frozen_string_literal: true

require_relative "sankey_parts"
require_relative "sankey_lanes"

module Quaack
  module Driver
    module Report
      # Where everything in one Sankey diagram goes (see SankeyDrawing, which
      # draws it, and SankeyLayers, which builds the layers and steps it lays out).
      #
      # It runs top to bottom, in the table's order. Each layer is a bar at LEFT,
      # SPINE_MAX times its share of the diagram's largest count wide, but never less
      # than MIN_THICKNESS, so a count of one stays visible beside thousands. A layer
      # the run didn't count is UNKNOWN_WIDTH wide.
      #
      # Between two layers is a step. What carries on runs straight down from the
      # layer's bottom edge into the next. Each drop leaves the bottom edge after the
      # carry and goes down and then right to a node in the column at NODE_X, in a row
      # of its own under the step's words. What a step set aside leaves the edge
      # first, turns left to a column of its own at the far left, and runs down to the
      # set-aside layer at the bottom, at HELD_X. A merge layer's sources come in from
      # lanes on the left (see SankeyLanes), or, for the diagram's first layer, from
      # bars spread across the whole picture; what carried on enters after them.
      # Each method here works out several x and y ends at once.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      class SankeyLayout
        include SankeyParts
        include SankeyLanes

        SPINE_MAX = 240.0
        MIN_THICKNESS = 2.0
        ZERO_BOX = 10.0
        UNKNOWN_WIDTH = SPINE_MAX * 0.3
        NODE_X = LEFT + SPINE_MAX + 40
        HELD_X = 16.0
        TOP = 8
        SLOT = 18
        MIN_GAP = 28
        HELD_GAP = 40
        PAD = 6

        attr_reader :layers, :steps

        def initialize(layers:, steps:)
          @layers = layers
          @steps = steps
          @into = steps.to_h { [it.into, it] }
          peak = [*layers.map { it.total.to_i }, *steps.map { step_through(it) },
                  *layers.flat_map { |layer| layer.sources.map(&:amount) }].max.to_i
          @scale = peak.zero? ? 0.0 : SPINE_MAX / peak
        end

        # How wide (or tall) a count is drawn.
        def thick(count) = count.to_i.positive? ? [@scale * count, MIN_THICKNESS].max : 0.0

        # Places everything, and returns the picture's height.
        def place
          y = TOP
          @layers.each do |layer|
            y += lead(layer)
            layer.y = y
            layer.x = layer.role == :held ? HELD_X : LEFT
            layer.width = width_of(layer)
            y += BAR_HEIGHT
          end
          @held_x = HELD_X
          @steps.each { place_step(it) }
          @layers.each { place_sources(it) }
          (y + TOP).ceil
        end

        private

        # What leaves a layer on a step: what carries on, and its sinks.
        def step_through(step) = [step.top, step.bottom].compact.max.to_i + (step.drops + step.held).sum(&:amount)

        def row(flow) = [thick(flow.amount) + 4, SLOT].max

        def rows(flows) = flows.sum { row(it) }

        # The room above a layer: for its step from the layer before, or its spread sources.
        def lead(layer)
          return HELD_GAP if layer.role == :held

          step = @into[layer]
          return (layer.spread && layer.sources.any? ? spread_block + PAD : 0) unless step

          words = step.line ? SLOT : 0
          below = words + rows(step.drops)
          above = layer.role == :merge ? block(layer.sources) : 0
          [MIN_GAP, (below.zero? ? 0 : below + (2 * PAD)) + (above.zero? ? 0 : above + PAD)].max
        end

        def width_of(layer)
          return UNKNOWN_WIDTH if layer.total.nil?
          return [thick(layer.total), MIN_THICKNESS].max unless layer.role == :merge

          added = layer.sources.sum(&:amount)
          [thick_sum(layer.sources) + thick(layer.total - added), MIN_THICKNESS].max
        end

        def thick_sum(flows) = flows.sum { thick(it.amount) }

        # The width of a carry's end: its count's, or the other end's if it wasn't counted.
        def wide(count, other)
          return thick(count) if count
          return thick(other) if other

          0.0
        end

        # Where a step's carry, drops, and set-aside go. The bottom edge holds, from the left,
        # what was set aside, then what carries on, then the drops. The drops, which go down
        # and then right, meet the edge last first, so no ribbons cross.
        def place_step(step)
          held = thick_sum(step.held)
          top = wide(step.top, step.bottom)
          bottom = wide(step.bottom, step.top)
          shift = step.into.role == :merge ? thick_sum(step.into.sources) : 0.0
          if top.positive? || bottom.positive?
            step.carry = Carry.new([LEFT + held, LEFT + held + top], [LEFT + shift, LEFT + shift + bottom],
                                   step.bottom || step.top)
          end
          step.below = placed(step.drops, step.from.bottom + PAD + (step.line ? SLOT : 0), "#{step.id}-out")
          line_up(step.below.reverse, LEFT + held + top)
          step.aside = asides(step)
        end

        # A step's set-aside ribbons, each in a column of its own, left to right in the order of the steps.
        def asides(step)
          x = LEFT
          step.held.each_with_index.map do |flow, k|
            wide = thick(flow.amount)
            Aside.new("#{step.id}-aside#{k}", flow, [x, x + wide], [@held_x, @held_x + wide], step.into.y).tap do
              x += wide
              @held_x += wide
            end
          end
        end

        # The flows' places, in order from first, one row each.
        def placed(flows, first, prefix)
          top = first
          flows.each_with_index.map do |flow, k|
            Placed.new("#{prefix}#{k}", flow, top + (row(flow) / 2.0), thick(flow.amount)).tap { top += row(flow) }
          end
        end

        # Sets each place's x, side by side from x.
        def line_up(places, start)
          places.each { |place| place.x = start.tap { start += place.thickness } }
        end
      end
    end
  end
end
