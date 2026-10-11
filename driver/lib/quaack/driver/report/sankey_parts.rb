# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The parts of a Sankey diagram's layout (see SankeyLayout).
      module SankeyParts
        # Where a node's bar, and its ribbons' edges, start.
        LEFT = 16.0

        # One source or sink: its words, count, kind (:source, :drop, :held), and hover.
        Flow = Struct.new(:label, :amount, :kind, :tip, keyword_init: true)
        # One node down the middle. kind is :start, :stage, or :end; state is
        # :full, :partial (counted what came in only), or :unknown. The rest
        # (y, height, width, above, below) is the layout's.
        Stage = Struct.new(:id, :kind, :name, :state, :inn, :out, :sources, :sinks, :color, :line, :tip,
                           :carry_tip, :y, :height, :width, :above, :below, keyword_init: true) do
          # What it counted going on, and coming in, or nil if it didn't count it.
          def went_on = state == :full ? out : nil

          def came_in = state == :unknown ? nil : inn

          def bottom = y + height
        end
        # A source or sink with its place: where its node's centre is, how
        # thick, and where its ribbon meets the bar's edge (x).
        Placed = Struct.new(:id, :flow, :centre, :thickness, :x) do
          def edge = [x, x + thickness]

          def upper = centre - (thickness / 2)

          def lower = centre + (thickness / 2)

          def span = [upper, lower]
        end
        # A source's flat bar, in its own lane on the row where it arrives, with its label
        # above it. Its ribbon runs down from the bar and merges into its stage's flow, whose
        # top edge it meets at edge_x.
        Source = Struct.new(:id, :flow, :thickness, :bar_x, :edge_x, :bar_y, :label_y) do
          def bar_edge = [bar_x, bar_x + thickness]

          def edge = [edge_x, edge_x + thickness]
        end
        # A ribbon down the middle, from one node to the next, wide a at the top, b at the bottom.
        Carry = Struct.new(:from, :into, :wide_a, :wide_b, :amount, :grey) do
          # The [left, right] x of the ribbon at the top, and at the bottom.
          def from_edge = [LEFT, LEFT + wide_a]

          def into_edge = [LEFT, LEFT + wide_b]

          def kind = grey ? "carry unknown" : "carry"
        end
      end
    end
  end
end
