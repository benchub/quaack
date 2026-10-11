# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The parts of a Sankey diagram's layout (see SankeyLayout).
      module SankeyParts
        # Where the layers start: the lanes of later sources, and the column to the
        # set-aside layer, are to the left.
        LEFT = 330.0
        BAR_HEIGHT = 22

        # One source or sink: its words, count, kind (:source, :drop, :held), and hover.
        Flow = Struct.new(:label, :amount, :kind, :tip, keyword_init: true)
        # One stage, or a run of stages that only add, from the stage records (see
        # SankeyStages). kind is :start or :stage; state is :full, :partial (counted
        # what came in only), or :unknown.
        Stage = Struct.new(:id, :kind, :name, :state, :inn, :out, :sources, :sinks, :color, :tip,
                           :sentences, :keys, keyword_init: true) do
          def added = sources.sum(&:amount)

          def drops = sinks.reject { it.kind == :held }

          def held = sinks.select { it.kind == :held }
        end
        # A layer: a state, drawn as a bar as wide as its count (nil when it wasn't
        # counted). role is :start (what the diagram above sent), :merge (what came in
        # plus what a stage added, fed by its sources), :after (what went on after a
        # stage's drops), or :held (what the diagram set aside for testing during
        # ranking). spread is whether its sources span the whole picture. The rest
        # (y, x, width, above) is the layout's.
        Layer = Struct.new(:id, :role, :name, :state, :total, :line, :tip, :color, :sources, :spread,
                           :y, :x, :width, :above, keyword_init: true) do
          def bottom = y + BAR_HEIGHT

          def grey? = state != :full
        end
        # A transition from one layer into the next. line is its step's words (nil for a
        # carry into a merge layer); top and bottom are the carry's counts at each end
        # (nil when not counted); drops and held are the step's sinks. The layout sets
        # carry, below (the drops' places), and aside (the set-aside ribbons' places).
        Step = Struct.new(:id, :from, :into, :line, :top, :bottom, :drops, :held, :tip, :carry_tip, :grey,
                          :carry, :below, :aside, keyword_init: true)
        # A sink with its place: where its node's centre is, how thick, and where its
        # ribbon meets the bar's edge (x).
        Placed = Struct.new(:id, :flow, :centre, :thickness, :x) do
          def edge = [x, x + thickness]

          def upper = centre - (thickness / 2)

          def lower = centre + (thickness / 2)

          def span = [upper, lower]
        end
        # A source's flat bar with its label above it. Its ribbon runs down from the bar into
        # its layer, whose top edge it meets at edge_x, wide as its count (none for zero).
        Source = Struct.new(:id, :flow, :thickness, :bar_x, :edge_x, :bar_y, :label_y, :room) do
          def right = bar_x + thickness

          def bar_edge = [bar_x, right]

          def wide = flow.amount.positive? ? thickness : 0.0

          def edge = [edge_x, edge_x + wide]
        end
        # A carry from one layer to the next: its [left, right] x at the top, and at the bottom.
        Carry = Struct.new(:from_edge, :into_edge, :amount)
        # What a step set aside: its ribbon leaves the layer's bottom edge, turns left to its
        # column, and runs down to the set-aside layer.
        Aside = Struct.new(:id, :flow, :edge, :column, :turn)
      end
    end
  end
end
