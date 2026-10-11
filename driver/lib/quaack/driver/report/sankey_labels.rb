# frozen_string_literal: true

require "erb"
require_relative "format"

module Quaack
  module Driver
    module Report
      # The words of a Sankey diagram (see SankeyDrawing): each layer's label, each
      # step's words, and each drop's label in one column, at TEXT_X, each in a row of
      # its own, and each source's label over its bar. No layer says how many came in
      # or were added: the ribbons show that, and the tooltips and the table have the
      # numbers.
      module SankeyLabels
        VIEW_WIDTH = 1040
        TEXT_X = 624
        LABEL_MAX = 64
        CHAR = 6.5
        LEFT_EDGE = 8

        private

        def words
          [*layers.map { tag("layer", TEXT_X, it.y + 15, cut(it.line, LABEL_MAX)) },
           *steps.flat_map { step_words(it) },
           *layers.flat_map { |layer| layer.above.map { source_label(it) } }]
        end

        # A step's words, then its drops' labels, each in a row of its own.
        def step_words(step)
          line = tag("step", TEXT_X, step.from.bottom + SankeyLayout::PAD + 12, cut(step.line, LABEL_MAX)) if step.line
          [line, *step.below.map { sink_label(it) }].compact
        end

        # A source's label, over its bar.
        def source_label(source)
          left, room, anchor = source.room ? [source.bar_x, (source.room / CHAR).floor] : source_anchor(source)
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
