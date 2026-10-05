# frozen_string_literal: true

require "erb"
require_relative "format"
require_relative "words"

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, drawn: each burndown table as an inline SVG
      # funnel above it, one band per row, in the table's order.
      #
      # A band is a trapezoid as wide at its top as the count that came in,
      # and at its bottom as the count that went on, on one scale per
      # funnel: its largest count is WIDTH. So a stage's drop is the band
      # narrowing, and a stage that adds (rewrite-rules, llm-rewrites,
      # operator-rewrites) widens. Beside it are the stage, its counts, and
      # its drops by reason, and its <title> says the whole row on hover.
      #
      # A row the run didn't record is drawn grey, dashed, and striped and says "not
      # recorded", never a zero. It has no count, so it takes no part in the
      # scale: it's as wide as the last counted band's bottom, to keep the
      # funnel's line, or WIDTH if none came before it.
      #
      # Every text in it goes through text, never Format.h, since an SVG
      # <text> can't hold the <code> h sets SQL in.
      module Funnel
        WIDTH = 320.0
        HEIGHT = 46
        GAP = 4
        TOP = 4
        LABEL_X = WIDTH + 20
        VIEW_WIDTH = 940
        LINE = 96
        STRIPE = 10

        # Words, escaped for the SVG, with any SQL marks dropped.
        def self.text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))

        # A funnel's SVG, for rows as Stages gives them.
        def funnel(id, title, rows)
          name = Funnel.text("#{title}, stage by stage. The table below has the exact numbers.")
          %(<svg id="funnel-#{id}" class="funnel" role="img" aria-labelledby="funnel-#{id}-title" ) +
            %(viewBox="0 0 #{VIEW_WIDTH} #{TOP + (rows.size * (HEIGHT + GAP))}">) +
            %(<title id="funnel-#{id}-title">#{name}</title>#{funnel_bands(rows).join}</svg>)
        end

        private

        def funnel_bands(rows)
          last = WIDTH
          funnel_widths(rows).each_with_index.map do |widths, i|
            next funnel_unknown(funnel_top(i), last, rows[i].first) unless widths

            last = widths.last
            funnel_band(funnel_top(i), widths, *rows[i])
          end
        end

        # Each row's widths at its top and bottom, on the scale of the
        # largest count, or nil for a row with no count.
        def funnel_widths(rows)
          counted = rows.map { |_, record, _| funnel_counted(record) }
          largest = counted.compact.flatten.max.to_i
          counted.map { it&.map { |count| funnel_scaled(count, largest) } }
        end

        def funnel_top(index) = TOP + (index * (HEIGHT + GAP))

        # A record's in and out, or nil if it has no count of both.
        def funnel_counted(record)
          counts = record&.values_at("in", "out")
          counts if counts&.all? { it.is_a?(Integer) && !it.negative? }
        end

        def funnel_scaled(count, largest) = largest.zero? ? 0.0 : (WIDTH * count / largest).round(1)

        def funnel_band(at, widths, name, record, stage)
          shape = funnel_polygon(at, *widths, 'fill="#2f6fb3" fill-opacity="0.8" stroke="#2f6fb3"')
          %(<g class="band"><title>#{Funnel.text(funnel_summary(name, record, stage))}</title>#{shape}) +
            %(#{funnel_words(at, name, funnel_label(record))}</g>)
        end

        def funnel_unknown(at, width, name)
          summary = Funnel.text("#{name}: #{Words::MISSING}. This run didn't count it, which doesn't mean none.")
          shape = funnel_polygon(at, width, width, 'fill="#eef0f3" stroke="#8a929d" stroke-dasharray="4 3"')
          %(<g class="band unknown"><title>#{summary}</title>#{shape}#{funnel_hatch(at, width)}) +
            %(#{funnel_words(at, name, Words::MISSING)}</g>)
        end

        # The trapezoid's corners: top left, top right, bottom right,
        # bottom left.
        def funnel_polygon(at, top, bottom, paint)
          middle = WIDTH / 2
          corners = [[middle - (top / 2), at], [middle + (top / 2), at], [middle + (bottom / 2), at + HEIGHT],
                     [middle - (bottom / 2), at + HEIGHT]]
          %(<polygon points="#{corners.map { |x, y| "#{x.round(2)},#{y}" }.join(" ")}" #{paint}/>)
        end

        # Grey stripes at 45 degrees across an unknown band, each cut to
        # the band's edges. (A <pattern> would need url(), which the report
        # never uses.)
        def funnel_hatch(at, width)
          left = (WIDTH - width) / 2
          right = left + width
          stripes = (left + STRIPE).step(right + HEIGHT, STRIPE).map { funnel_stripe(at, left, right, it) }
          %(<path class="hatch" d="#{stripes.join}" stroke="#b5bcc6" stroke-width="2"/>)
        end

        # The stripe that crosses the band's top line at across, as a path segment.
        def funnel_stripe(at, left, right, across)
          from = across <= right ? [across, at] : [right, at + across - right]
          to = across - HEIGHT >= left ? [across - HEIGHT, at + HEIGHT] : [left, at + across - left]
          "M#{from.map { it.round(1) }.join(",")}L#{to.map { it.round(1) }.join(",")}"
        end

        def funnel_words(at, name, label)
          %(<text class="stage" x="#{LABEL_X}" y="#{at + 18}">#{Funnel.text(name)}</text>) +
            %(<text class="counts" x="#{LABEL_X}" y="#{at + 37}">#{Funnel.text(label)}</text>)
        end

        # What's beside a band: its counts, and its drops by reason, cut to
        # fit. The band's <title> and the table have them whole.
        def funnel_label(record)
          counts = "#{Format.number(record["in"])} in, #{Format.number(record["out"])} out"
          counts += ", #{Format.number(record["set_aside"])} set aside" if record["set_aside"].to_i.positive?
          dropped = breakdown(record["dropped"].to_h)
          line = dropped == "none" ? counts : "#{counts} · dropped: #{dropped}"
          line.length > LINE ? "#{line[0, LINE - 1]}…" : line
        end

        def funnel_summary(name, record, stage)
          "#{name}: #{Format.number(record["in"])} came in. " \
            "Added: #{breakdown(record["added"].to_h, rules: stage == "rewrite-rules")}. " \
            "Dropped: #{breakdown(record["dropped"].to_h)}. Set aside: #{Format.number(record["set_aside"].to_i)}. " \
            "#{Format.number(record["out"])} went on."
        end
      end
    end
  end
end
