# frozen_string_literal: true

require "erb"
require_relative "format"

module Quaack
  module Driver
    module Report
      # The words of a Sankey diagram (see SankeyDrawing): a layer's label and each
      # sink's label in one column, at TEXT_X, each in a row of its own, and each
      # source's label on a line of its own over its bar. No layer says how many came
      # in or were added: the ribbons show that, and the tooltips and the table have
      # the numbers.
      module SankeyLabels
        VIEW_WIDTH = 1040
        TEXT_X = 624
        LABEL_MAX = 64
        CHAR = 6.5
        LEFT_EDGE = 8

        private

        def words
          nodes.flat_map do |node|
            [stage_words(node), *node.above.map { source_label(it) },
             *node.below.map { sink_label(it) }]
          end
        end

        # A source's label, over its bar.
        def source_label(source)
          left, room, anchor = source_anchor(source)
          tag("source", left, source.label_y, cut(source.flow.label, room), anchor)
        end

        # Where a source's label goes: starting at its bar's left edge if it fits before
        # the flow, or else ending at the bar's right edge, or further right if it needs
        # the room, cut to fit. [x, room, anchor].
        def source_anchor(source)
          room = ((SankeyParts::LEFT - 8 - source.bar_x) / CHAR).floor
          return [source.bar_x, room] if source.flow.label.length <= room

          right = label_end(source)
          [right, ((right - LEFT_EDGE) / CHAR).floor, "end"]
        end

        # Where a label that ends over its bar ends: at the bar's right edge, or further
        # right if it needs the room, but before the flow.
        def label_end(source)
          needs = LEFT_EDGE + (source.flow.label.length * CHAR)
          needs.clamp(source.right, SankeyParts::LEFT - 8)
        end

        def stage_words(node)
          tag(node.kind == :stage ? "stage" : "flow", TEXT_X, node.y + 15, cut(node.line, LABEL_MAX))
        end

        def sink_label(placed) = tag("flow", TEXT_X, placed.centre + 4, cut(placed.flow.label, LABEL_MAX))

        # The words, cut to room characters, with an ellipsis if they were longer.
        def cut(words, room) = words.length > room ? "#{words[0, room - 1]}…" : words

        def tag(kind, left, height, shown, anchor = nil)
          edge = %( text-anchor="#{anchor}") if anchor
          %(<text class="#{kind}" x="#{left.round(2)}" y="#{height.round(2)}"#{edge}>#{text(shown)}</text>)
        end

        def text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))
      end
    end
  end
end
