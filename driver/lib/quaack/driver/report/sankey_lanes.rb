# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Where a stage's sources go (see SankeyLayout). Each is a flat bar of its
      # own in a lane to the left of the flow, the lanes side by side up to LANE_RIGHT,
      # about LANE_GAP apart, on the row above the stage's bar, with its label on a line
      # of its own above it. The ribbons run down through MERGE and meet the stage's top
      # edge from its left, in the same order, before what carried on.
      module SankeyLanes
        LANE_RIGHT = SankeyParts::LEFT - 30
        LANE_GAP = 10.0
        FLAT = 10
        MERGE = 44
        LABEL_LINE = 16
        LABEL_GAP = 6

        private

        # The height of a stage's sources: a line for each label, then the flat bars, then
        # where their ribbons merge into the stage's bar. None if it has none.
        def block(sources) = sources.empty? ? 0 : (sources.size * LABEL_LINE) + LABEL_GAP + FLAT + MERGE

        # The node's sources' bars, in their lanes, and where their ribbons meet its top edge.
        def place_above(node)
          bars, edges = lane_starts(node.sources.map { thick(it.amount) })
          node.above = node.sources.each_with_index.map { |flow, k| lane_source(node, flow, k, bars[k], edges[k]) }
        end

        # Where each width's bar starts in the lanes, and where its ribbon meets the top edge.
        def lane_starts(wide)
          gap = lane_gap(wide)
          [starts(wide, LANE_RIGHT - wide.sum - (gap * (wide.size - 1)), gap), starts(wide, SankeyParts::LEFT, 0)]
        end

        # Where each of the widths starts, side by side from first, gap apart.
        def starts(wide, first, gap) = wide.each_index.map { first + wide.first(it).sum + (gap * it) }

        # The gap between lanes: LANE_GAP, less if the bars leave no room for it.
        def lane_gap(wide)
          room = (LANE_RIGHT - 10 - wide.sum) / [wide.size - 1, 1].max
          room.clamp(2.0, LANE_GAP)
        end

        def lane_source(node, flow, index, bar_x, edge_x)
          bar_y = node.y - MERGE - FLAT
          label_y = bar_y - LABEL_GAP - ((node.sources.size - 1 - index) * LABEL_LINE)
          SankeyParts::Source.new("#{node.id}-in#{index}", flow, thick(flow.amount), bar_x, edge_x, bar_y, label_y)
        end
      end
    end
  end
end
