# frozen_string_literal: true

require "erb"
require_relative "format"
require_relative "words"
require_relative "stage_sentences"

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, drawn: each burndown table as an inline SVG
      # funnel above it, one band per row, in the table's order.
      #
      # The width is what's in the pipe, on one scale per funnel: its
      # widest point is WIDTH. The first band is a rectangle, as wide at its
      # top as at its bottom (zero wide if its stage added nothing). Every band
      # starts as wide as the one before it ended, so a stage that adds
      # nothing and drops nothing keeps its width, one that drops or sets
      # aside narrows, and one that adds (rewrite-rules, llm-rewrites,
      # operator-rewrites) widens. A band's bottom is its top plus what it
      # went on with, less what came in: top + added - dropped - set aside.
      # A later band that added has a third width, top + added, at its
      # middle, drawn as a lighter slice on each side (funnel_added).
      # The drawing carries that running width whatever a record's own
      # "in" says, so a count that doesn't join up shows in the table, not
      # as a gap in the funnel. The bands touch, so the funnel reads as one
      # shape; each stage's color tells them apart. Beside each band are the
      # stage, what went on, and its drops by reason. Its <title> is the
      # stage's sentence, after a short note for a stage the run didn't fully
      # record. The table has the counts.
      # Each stage has its own color (COLORS), the same in every report.
      #
      # A row the run didn't record is drawn grey, dashed, and striped and
      # says "not recorded", never a zero. It has no count, so it keeps the
      # running width, but never narrower than UNKNOWN, so it can't look like
      # a band that counted zero.
      #
      # A row that counted what came in but not what went on is drawn as
      # far as it's known: a solid line along its top at the running width,
      # over the unknown band's grey stripes. It keeps the running width.
      #
      # Every text in it goes through text, never Format.h, since an SVG
      # <text> can't hold the <code> h sets SQL in.
      module Funnel # rubocop:disable Metrics/ModuleLength
        WIDTH = 320.0
        UNKNOWN = 96.0
        HEIGHT = 46
        TOP = 4
        LABEL_X = WIDTH + 20
        VIEW_WIDTH = 940
        LINE = 96
        STRIPE = 10
        BLUE = "var(--st-default)"
        KNOWN_GREY = "var(--known-line)"
        # One color per stage, a CSS variable the template defines for both themes.
        COLORS = {
          "index-from-query" => "var(--st-blue)",
          "index-from-plan" => "var(--st-teal)",
          "index-dedupe" => "var(--st-violet)",
          "index-test" => "var(--st-brown)",
          "llm-index-ideas" => "var(--st-rose)",
          "llm-index-refine" => "var(--st-green)",
          "index-rank" => "var(--st-gold)",
          "rewrite-rules" => "var(--st-blue)",
          "llm-rewrites" => "var(--st-violet)",
          "operator-rewrites" => "var(--st-teal)",
          "assumption-check" => "var(--st-brown)",
          "plan-pruning" => "var(--st-rose)",
          "rewrite-test" => "var(--st-green)",
          "counterexamples" => "var(--st-gold)",
          "rewrite-index-ideas" => "var(--st-indigo)",
          "measurement" => "var(--st-slate)"
        }.freeze
        UNCOUNTED = 'style="fill: var(--uncounted-fill); stroke: var(--uncounted-stroke)" stroke-dasharray="4 3"'
        NOT_NONE = "This run didn't count it, which doesn't mean none."

        # Words, escaped for the SVG, with any SQL marks dropped.
        def self.text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))

        # A funnel's SVG, for rows as Stages gives them.
        def funnel(id, title, rows, of_rewrite: false)
          name = Funnel.text("#{title}, stage by stage. The table below has the exact numbers.")
          %(<svg id="funnel-#{id}" class="funnel" role="img" aria-labelledby="funnel-#{id}-title" ) +
            %(viewBox="0 0 #{VIEW_WIDTH} #{(TOP * 2) + (rows.size * HEIGHT)}">) +
            %(<title id="funnel-#{id}-title">#{name}</title>#{funnel_bands(rows, of_rewrite).join}</svg>)
        end

        private

        def funnel_bands(rows, of_rewrite)
          funnel_widths(rows).each_with_index.map do |widths, i|
            at = funnel_top(i)
            case widths
            in [width, nil, _] then funnel_unknown(at, [width, UNKNOWN].max, *rows[i].values_at(0, 2), of_rewrite)
            in [width, :partial, _] then funnel_partial(at, width, [width, UNKNOWN].max, *rows[i], of_rewrite)
            else funnel_band(at, widths, *rows[i], of_rewrite)
            end
          end
        end

        # Each row's [top, bottom] widths, on the scale of the widest point.
        # The running width, in counts, is zero before the first row. A row
        # with both counts moves it by out - in, except the first row, which
        # sets it to its out, so its top is as wide as its bottom (a
        # rectangle). A row with no count is
        # [width, nil], and one with only what came in [width, :partial], at
        # the running width and leaving it be.
        #
        # A counted row also has its peak: what came in plus what it added,
        # its widest point, drawn at the band's middle (funnel_added). The
        # first row's peak is its out, since its width is what it added.
        def funnel_widths(rows)
          running = 0
          drawn = rows.each_with_index.map do |(_, record, _), i|
            top, bottom, running = funnel_row(running, *funnel_counted(record), first: i.zero?)
            [top, bottom, funnel_peak(top, bottom, record, first: i.zero?)]
          end
          largest = drawn.flat_map { it.grep(Integer) }.max.to_i
          drawn.map { |widths| widths.map { funnel_scaled(it, largest) } }
        end

        # A counted row's widest point, in counts: its top plus what it
        # added, never narrower than its bottom. nil for a row not counted.
        def funnel_peak(top, bottom, record, first:)
          return unless bottom.is_a?(Integer)
          return bottom if first

          [top + funnel_added_count(record), bottom].max
        end

        def funnel_added_count(record) = record["added"].to_h.values.grep(Integer).reject(&:negative?).sum

        # A row's [top, bottom, running width after it], in counts. The
        # first row's top is as wide as its bottom, so it sets the running
        # width to its out; later rows move it by out - in.
        def funnel_row(running, inn, out, first:)
          return [running, funnel_bottom(inn, out, running), running] unless out

          after = first ? out : [running + out - inn, 0].max
          [first ? after : running, after, after]
        end

        # A row's bottom, in counts: where the running width ended up, or
        # :partial for a row with only what came in, or nil for one with nothing.
        def funnel_bottom(inn, out, running) = out ? running : (:partial if inn)

        def funnel_top(index) = TOP + (index * HEIGHT)

        # A record's [in, out], [in, nil] if it has no out, or [nil, nil] if
        # it has no count of what came in, or a count that can't be one.
        def funnel_counted(record)
          inn, out = record&.values_at("in", "out")
          return [nil, nil] unless funnel_count?(inn)

          return [inn, nil] if out.nil?

          funnel_count?(out) ? [inn, out] : [nil, nil]
        end

        def funnel_count?(count) = count.is_a?(Integer) && !count.negative?

        # A count's width on the scale, or the marker (nil, :partial) as it is.
        def funnel_scaled(count, largest)
          return count unless count.is_a?(Integer)

          largest.zero? ? 0.0 : (WIDTH * count / largest).round(1)
        end

        def funnel_band(at, widths, name, record, stage, of_rewrite) # rubocop:disable Metrics/ParameterLists
          color = COLORS.fetch(stage, BLUE)
          top, bottom, peak = widths
          shape = funnel_polygon(at, top, bottom, %(style="fill: #{color}; stroke: #{color}" fill-opacity="0.85"))
          added = peak > top
          %(<g class="band">#{funnel_tip(funnel_summary("", stage, of_rewrite))}#{shape}) +
            (added ? funnel_added(at, widths, color) : "") +
            %(#{funnel_words(at, name, funnel_label(record, stage, added:))}</g>)
        end

        # What a stage added, as a lighter slice on each side of its band:
        # from the band's top corner out to its peak, at the band's middle,
        # and back to its bottom corner. So a band reads three widths: what
        # came in at its top, that plus what it added at its middle, and
        # what went on at its bottom.
        def funnel_added(at, widths, color)
          top, bottom, peak = widths.map { it / 2 }
          [-1, 1].map do |side|
            corners = [[top, at], [peak, at + (HEIGHT / 2)], [bottom, at + HEIGHT]]
                      .map { |x, y| "#{((WIDTH / 2) + (side * x)).round(2)},#{y}" }
            paint = %(style="fill: #{color}; stroke: #{color}" fill-opacity="0.35" stroke-dasharray="3 2")
            %(<polygon class="added" points="#{corners.join(" ")}" #{paint}/>)
          end.join
        end

        def funnel_unknown(at, width, name, stage, of_rewrite)
          summary = funnel_summary("#{name}: #{Words::MISSING}. #{NOT_NONE}", stage, of_rewrite)
          shape = funnel_polygon(at, width, width, UNCOUNTED)
          %(<g class="band unknown">#{funnel_tip(summary)}#{shape}#{funnel_hatch(at, width)}) +
            %(#{funnel_words(at, name, Words::MISSING)}</g>)
        end

        # A band that counted what came in, known wide, but not what went
        # on: the unknown band, width wide, under a solid line for its top.
        def funnel_partial(at, known, width, name, record, stage, of_rewrite) # rubocop:disable Metrics/ParameterLists
          went_on = "How many went on: #{Words::MISSING}. #{NOT_NONE}"
          summary = funnel_summary(went_on, stage, of_rewrite)
          left = (WIDTH - known) / 2
          line = %(<line class="known" x1="#{left.round(2)}" y1="#{at}" x2="#{(left + known).round(2)}" y2="#{at}" ) +
                 %(style="stroke: #{KNOWN_GREY}" stroke-width="4"/>)
          %(<g class="band partial">#{funnel_tip(summary)}#{funnel_polygon(at, width, width, UNCOUNTED)}) +
            %(#{funnel_hatch(at, width)}#{line}#{funnel_words(at, name, funnel_label(record, stage, "went on #{Words::MISSING}"))}</g>)
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
          %(<path class="hatch" d="#{stripes.join}" style="stroke: var(--hatch)" stroke-width="2"/>)
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
        # With added, it starts with how many the stage added.
        def funnel_label(record, stage, went_on = "#{Format.number(record["out"])} went on", added: false)
          counts = went_on
          counts = "#{Format.number(funnel_added_count(record))} added, #{counts}" if added
          if record["set_aside"].to_i.positive?
            counts += ", #{Format.number(record["set_aside"])} set aside for testing during ranking"
          end
          dropped = breakdown(record["dropped"].to_h, stage:)
          line = dropped == "none" ? counts : "#{counts} · dropped: #{dropped}"
          line.length > LINE ? "#{line[0, LINE - 1]}…" : line
        end

        # A band's <title>, or nothing when there's no text to show.
        def funnel_tip(text) = text.empty? ? "" : "<title>#{Funnel.text(text)}</title>"

        # The hover: a note when the run didn't record the stage in full,
        # then the stage's sentence, if it has one. The table has the counts.
        def funnel_summary(note, stage, of_rewrite)
          [note, StageSentences.for(stage, of_rewrite:)].compact.reject(&:empty?).join(" ")
        end
      end
    end
  end
end
