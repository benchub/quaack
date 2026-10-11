# frozen_string_literal: true

require_relative "sankey_parts"
require_relative "sankey_lanes"

module Quaack
  module Driver
    module Report
      # Where everything in one Sankey diagram goes (see SankeyDrawing, which
      # draws it, and Sankey, which builds what it lays out).
      #
      # It runs top to bottom, the way the funnel does, so a stage is a row
      # in the same order as its table. A count is drawn SPINE_MAX times its
      # share of the diagram's widest node wide (or tall, at a flow's other
      # end), but never less than MIN_THICKNESS, so a count of one stays
      # visible beside thousands. A count of zero has no ribbon, input, or
      # sink; a stage that counted nothing is still a node, MIN_THICKNESS wide.
      #
      # A stage is a bar. What carried on from the stage above, then each
      # source of its added, enter its top edge, so its width is what came in plus
      # what was added: the sources, from the left, and then what carried on. Each
      # source is a flat bar of its own in a lane to the left of the flow (see
      # SankeyLanes) on the stage's row, above the bar, with its label on a line of
      # its own over it; its ribbon runs down and merges into the bar's top edge. What carries on,
      # then each drop reason and the held back count, leave its bottom edge,
      # the carry first, and go down and then right to nodes in the column at
      # NODE_X, in the gap below it. A gap is as tall as the rows it holds, so
      # no two labels meet.
      class SankeyLayout
        include SankeyParts
        include SankeyLanes

        SPINE_MAX = 240.0
        MIN_THICKNESS = 2.0
        UNKNOWN_WIDTH = SPINE_MAX * 0.3
        NODE_X = LEFT + SPINE_MAX + 40
        TOP = 8
        BAR_HEIGHT = 22
        EDGE_HEIGHT = 22
        SLOT = 18
        MIN_GAP = 28
        PAD = 6

        attr_reader :nodes, :carries

        def initialize(start:, stages:, finish:)
          @nodes = [start, *stages, finish].compact
          peak = @nodes.flat_map { |node| counts_through(node) }.max.to_i
          @scale = peak.zero? ? 0.0 : SPINE_MAX / peak
        end

        # How wide (or tall) a count is drawn.
        def thick(count) = count.to_i.positive? ? [@scale * count, MIN_THICKNESS].max : 0.0

        # Places everything, and returns the picture's height.
        def place
          @carries = @nodes.each_cons(2).map { |from, into| carry_between(from, into) }
          height = stack
          @nodes.each_with_index do |node, index|
            node.width = width_of(node, index)
            place_flows(node, index)
          end
          height
        end

        private

        # What goes into a node, and what comes out.
        def counts_through(node)
          [node.inn.to_i + node.sources.sum(&:amount), (node.out || node.inn).to_i + node.sinks.sum(&:amount)]
        end

        def row(flow) = [thick(flow.amount) + 4, SLOT].max

        def rows(flows) = flows.sum { row(it) }

        # Each node's y, over the gap below it. Returns the picture's height.
        def stack
          y = TOP + lead
          @nodes.each_with_index do |node, index|
            node.y = y
            node.height = node.kind == :stage ? BAR_HEIGHT : EDGE_HEIGHT
            y += node.height + gap_after(index)
          end
          (y + TOP).ceil
        end

        # The room above the first node for its sources, when it has any.
        def lead = block(@nodes.first.sources).then { it.zero? ? 0 : it + PAD }

        def gap_after(index)
          nxt = @nodes[index + 1]
          below = rows(@nodes[index].sinks)
          above = nxt ? block(nxt.sources) : 0
          need = (below.zero? ? 0 : below + (2 * PAD)) + (above.zero? ? 0 : above + PAD)
          nxt ? [MIN_GAP, need].max : need
        end

        def width_of(node, index)
          return [UNKNOWN_WIDTH, carry_wide(index - 1, :wide_b), carry_wide(index)].max if node.state == :unknown

          [thick(node.inn) + thick_sum(node.sources), carry_wide(index) + thick_sum(node.sinks), MIN_THICKNESS].max
        end

        def thick_sum(flows) = flows.sum { thick(it.amount) }

        # Where the node's sources, above it, and sinks, below it, go. Their ribbons meet
        # its edges side by side, after what carries on. The sinks, which go down and then
        # right, meet the bottom edge last first, so no ribbons cross; the sources' bars
        # are in the same order as where they meet, so theirs don't either.
        def place_flows(node, index)
          place_above(node)
          place_below(node, index)
        end

        def place_below(node, index)
          node.below = placed(node.sinks, node.bottom + PAD, "#{node.id}-out")
          line_up(node.below.reverse, carry_wide(index))
        end

        def carry_wide(index, side = :wide_a)
          index.negative? ? 0.0 : (@carries[index]&.public_send(side) || 0.0)
        end

        # The ribbon from a node to the next. A node that didn't count its way on
        # takes the width of the other end; there is none if neither counted.
        def carry_between(from, into)
          amounts = carried(from, into) or return
          wide = amounts.map { thick(it) }
          return if wide.all?(&:zero?)

          Carry.new(from:, into:, wide_a: wide[0], wide_b: wide[1], amount: amounts[0],
                    grey: from.state != :full || into.state == :unknown, shift: thick_sum(into.sources))
        end

        def carried(from, into)
          went = from.went_on
          came = into.came_in
          [went || came, came || went] if went || came
        end

        # The flows' places, in order from first, one row each.
        def placed(flows, first, prefix)
          top = first
          flows.each_with_index.map do |flow, k|
            Placed.new("#{prefix}#{k}", flow, top + (row(flow) / 2.0), thick(flow.amount)).tap { top += row(flow) }
          end
        end

        # Sets each place's x, side by side after what carries on, which is carried wide.
        def line_up(places, carried)
          x = LEFT + carried
          places.each { |place| place.x = x.tap { x += place.thickness } }
        end
      end
    end
  end
end
