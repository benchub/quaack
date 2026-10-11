# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Where a stage's sources go (see SankeyLayout). Each is a flat bar of its
      # own in a lane, the lanes side by side from LANE_X, LANE_GAP apart, on the
      # row above the stage's bar, with its label on a line of its own above it,
      # the first source's highest. The ribbons run down through MERGE and
      # meet the stage's top edge in the same order, after what carried on.
      module SankeyLanes
        LANE_X = SankeyParts::LEFT + 240.0 + 30
        LANE_GAP = 16.0
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
          bar_x = LANE_X
          edge_x = SankeyParts::LEFT + thick(node.inn)
          node.above = node.sources.each_with_index.map do |flow, k|
            wide = thick(flow.amount)
            lane_source(node, flow, k, bar_x, edge_x).tap do
              bar_x += wide + LANE_GAP
              edge_x += wide
            end
          end
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
