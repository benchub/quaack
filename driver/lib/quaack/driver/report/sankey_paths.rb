# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The outlines of a Sankey diagram's ribbons (see SankeyDrawing), as
      # SVG path data. A ribbon is a band between two cubic curves, each
      # given as its four points [start, control, control, end]. The curves
      # are ordered so that the two sides of a ribbon never cross.
      module SankeyPaths
        module_function

        def point(pair) = "#{pair[0].round(2)},#{pair[1].round(2)}"

        def lerp(from, to, fraction) = from + ((to - from) * fraction)

        # A band: forward's curve, a straight line to where back's curve starts, and back's curve.
        def band(forward, back)
          "M#{point(forward[0])} C#{forward[1..].map { point(it) }.join(" ")} " \
            "L#{point(back[0])} C#{back[1..].map { point(it) }.join(" ")} Z"
        end

        # From a node's bottom edge, at from_y, down to the next node's top edge, at into_y. Each edge is
        # given as its [left, right] x.
        def carry(from_y, into_y, from_edge, into_edge)
          middle = (from_y + into_y) / 2.0
          band([[from_edge[0], from_y], [from_edge[0], middle], [into_edge[0], middle], [into_edge[0], into_y]],
               [[into_edge[1], into_y], [into_edge[1], middle], [from_edge[1], middle], [from_edge[1], from_y]])
        end

        # From a stage's bottom edge, at y, down and then right to a sink's node at x, whose
        # ribbon is upper to lower. The edge's left end goes to the lower side.
        def sink(edge, y_edge, x_node, upper, lower)
          left, right = edge
          band([[left, y_edge], [left, lerp(y_edge, lower, 0.6)], [lerp(left, x_node, 0.4), lower], [x_node, lower]],
               [[x_node, upper], [lerp(right, x_node, 0.4), upper], [right, lerp(y_edge, upper, 0.6)], [right, y_edge]])
        end
      end
    end
  end
end
