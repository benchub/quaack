# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Where a merge layer's sources go (see SankeyLayout). Each is a flat bar as
      # wide as its count, or a thin tick for a count of zero, with its label above
      # it, and its ribbon runs down and meets the layer's top edge from its left, in
      # the same order as the bars, so none cross.
      #
      # The diagram's first layer spreads its bars across the whole picture, side by
      # side with even gaps, every label on one line, each cut to the room before the
      # next bar. A later layer's bars are in lanes to the left of the flow, side by
      # side up to LANE_RIGHT, about LANE_GAP apart, each label on a line of its own.
      # Each method here works out several x and y ends at once.
      # rubocop:disable-next Metrics/AbcSize
      module SankeyLanes
        LANE_RIGHT = SankeyParts::LEFT - 30
        LANE_GAP = 10.0
        FLAT = 10
        MERGE = 44
        LABEL_LINE = 16
        LABEL_GAP = 6
        SPREAD_LEFT = 8.0
        SPREAD_RIGHT = 1032.0

        private

        # The height of a later layer's sources: a line for each label, then the flat bars,
        # then where their ribbons merge into the layer. None if it has none.
        def block(sources) = sources.empty? ? 0 : (sources.size * LABEL_LINE) + LABEL_GAP + FLAT + MERGE

        # The height of the first layer's spread sources: one line of labels, the bars, and the merge.
        def spread_block = LABEL_LINE + LABEL_GAP + FLAT + MERGE

        def bar(amount) = [thick(amount), SankeyLayout::MIN_THICKNESS].max

        # Where the layer's sources go, if it has any.
        def place_sources(layer)
          layer.above = []
          return if layer.sources.empty?

          wide = layer.sources.map { bar(it.amount) }
          edges = starts(layer.sources.map { thick(it.amount) }, SankeyParts::LEFT, 0)
          layer.above = layer.spread ? spread(layer, wide, edges) : lanes(layer, wide, edges)
        end

        def spread(layer, wide, edges)
          gap = (SPREAD_RIGHT - SPREAD_LEFT - wide.sum) / wide.size
          bars = starts(wide, SPREAD_LEFT, gap)
          bar_y = layer.y - MERGE - FLAT
          layer.sources.each_with_index.map do |flow, k|
            room = (bars[k + 1] || SPREAD_RIGHT) - bars[k] - 8
            SankeyParts::Source.new("#{layer.id}-in#{k}", flow, wide[k], bars[k], edges[k], bar_y, bar_y - LABEL_GAP,
                                    room)
          end
        end

        def lanes(layer, wide, edges)
          gap = lane_gap(wide)
          bars = starts(wide, LANE_RIGHT - wide.sum - (gap * (wide.size - 1)), gap)
          bar_y = layer.y - MERGE - FLAT
          count = layer.sources.size
          layer.sources.each_with_index.map do |flow, k|
            label_y = bar_y - LABEL_GAP - ((count - 1 - k) * LABEL_LINE)
            SankeyParts::Source.new("#{layer.id}-in#{k}", flow, wide[k], bars[k], edges[k], bar_y, label_y, nil)
          end
        end

        # Where each of the widths starts, side by side from first, gap apart.
        def starts(wide, first, gap) = wide.each_index.map { first + wide.first(it).sum + (gap * it) }

        # The gap between lanes: LANE_GAP, less if the bars leave no room for it.
        def lane_gap(wide)
          room = (LANE_RIGHT - 10 - wide.sum) / [wide.size - 1, 1].max
          room.clamp(2.0, LANE_GAP)
        end
      end
    end
  end
end
