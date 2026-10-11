# frozen_string_literal: true

require "erb"
require_relative "format"

module Quaack
  module Driver
    module Report
      # The words of a Sankey diagram (see SankeyDrawing): a stage's name and
      # counts and each sink's label in one column, at TEXT_X, each in a row of its
      # own, and each source's label over its bar, on a line of its own.
      module SankeyLabels
        VIEW_WIDTH = 940
        TEXT_X = 314
        LABEL_MAX = 88
        CHAR = 6.5

        private

        def words
          nodes.flat_map do |node|
            [*stage_words(node), *node.above.map { source_label(it) },
             *node.below.map { line("flow", it.centre + 4, it.flow.label) }]
          end
        end

        # A source's label, over its bar, cut to end inside the picture.
        def source_label(source)
          room = ((VIEW_WIDTH - 8 - source.bar_x) / CHAR).floor
          line("source", source.label_y, source.flow.label, source.bar_x.round(2), room)
        end

        def stage_words(node)
          return [line("flow", node.y + 15, node.line)] unless node.kind == :stage

          [line("stage", node.y + 15, node.name), line("counts", node.y + 31, node.line)]
        end

        def line(kind, height, words, left = TEXT_X, room = LABEL_MAX)
          shown = words.length > room ? "#{words[0, room - 1]}…" : words
          %(<text class="#{kind}" x="#{left}" y="#{height.round(2)}">#{text(shown)}</text>)
        end

        def text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))
      end
    end
  end
end
