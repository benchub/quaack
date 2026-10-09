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
      # widest point is WIDTH. The first band starts at zero. Every band
      # starts as wide as the one before it ended, so a stage that adds
      # nothing and drops nothing keeps its width, one that drops or sets
      # aside narrows, and one that adds (rewrite-rules, llm-rewrites,
      # operator-rewrites) widens. A band's bottom is its top plus what it
      # went on with, less what came in: top + added - dropped - set aside.
      # The drawing carries that running width whatever a record's own
      # "in" says, so a count that doesn't join up shows in the table, not
      # as a gap in the funnel. Beside each band are the stage, its counts,
      # and its drops by reason, and its <title> says the whole row on hover.
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
        GAP = 4
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
            %(viewBox="0 0 #{VIEW_WIDTH} #{TOP + (rows.size * (HEIGHT + GAP))}">) +
            %(<title id="funnel-#{id}-title">#{name}</title>#{funnel_bands(rows, of_rewrite).join}</svg>)
        end

        private

        def funnel_bands(rows, of_rewrite)
          funnel_widths(rows).each_with_index.map do |widths, i|
            at = funnel_top(i)
            case widths
            in [width, nil] then funnel_unknown(at, [width, UNKNOWN].max, *rows[i].values_at(0, 2), of_rewrite)
            in [width, :partial] then funnel_partial(at, width, [width, UNKNOWN].max, *rows[i], of_rewrite)
            else funnel_band(at, widths, *rows[i], of_rewrite)
            end
          end
        end

        # Each row's [top, bottom] widths, on the scale of the widest point.
        # The running width, in counts, starts at zero, and a row with both
        # counts moves it by out - in. A row with no count is [width, nil],
        # and one with only what came in [width, :partial], at the running
        # width and leaving it be.
        def funnel_widths(rows)
          running = 0
          drawn = rows.map do |_, record, _|
            inn, out = funnel_counted(record)
            top = running
            running = [running + out - inn, 0].max if out
            [top, funnel_bottom(inn, out, running)]
          end
          largest = drawn.flat_map { it.grep(Integer) }.max.to_i
          drawn.map { |top, bottom| [funnel_scaled(top, largest), funnel_scaled(bottom, largest)] }
        end

        # A row's bottom, in counts: where the running width ended up, or
        # :partial for a row with only what came in, or nil for one with nothing.
        def funnel_bottom(inn, out, running) = out ? running : (:partial if inn)

        def funnel_top(index) = TOP + (index * (HEIGHT + GAP))

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
          shape = funnel_polygon(at, *widths, %(style="fill: #{color}; stroke: #{color}" fill-opacity="0.85"))
          %(<g class="band"><title>#{Funnel.text(funnel_summary(name, record, stage, of_rewrite:))}</title>#{shape}) +
            %(#{funnel_words(at, name, funnel_label(record, stage))}</g>)
        end

        def funnel_unknown(at, width, name, stage, of_rewrite)
          summary = Funnel.text("#{name}: #{Words::MISSING}. #{NOT_NONE}#{funnel_does(stage, of_rewrite)}")
          shape = funnel_polygon(at, width, width, UNCOUNTED)
          %(<g class="band unknown"><title>#{summary}</title>#{shape}#{funnel_hatch(at, width)}) +
            %(#{funnel_words(at, name, Words::MISSING)}</g>)
        end

        # A band that counted what came in, known wide, but not what went
        # on: the unknown band, width wide, under a solid line for its top.
        def funnel_partial(at, known, width, name, record, stage, of_rewrite) # rubocop:disable Metrics/ParameterLists
          went_on = "How many went on: #{Words::MISSING}. #{NOT_NONE}"
          summary = Funnel.text(funnel_summary(name, record, stage, went_on, of_rewrite:))
          left = (WIDTH - known) / 2
          line = %(<line class="known" x1="#{left.round(2)}" y1="#{at}" x2="#{(left + known).round(2)}" y2="#{at}" ) +
                 %(style="stroke: #{KNOWN_GREY}" stroke-width="4"/>)
          %(<g class="band partial"><title>#{summary}</title>#{funnel_polygon(at, width, width, UNCOUNTED)}) +
            %(#{funnel_hatch(at, width)}#{line}#{funnel_words(at, name, funnel_label(record, stage, "out #{Words::MISSING}"))}</g>)
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
        def funnel_label(record, stage, out = "#{Format.number(record["out"])} out")
          counts = "#{Format.number(record["in"])} in, #{out}"
          counts += ", #{Format.number(record["set_aside"])} set aside" if record["set_aside"].to_i.positive?
          dropped = breakdown(record["dropped"].to_h, stage:)
          line = dropped == "none" ? counts : "#{counts} · dropped: #{dropped}"
          line.length > LINE ? "#{line[0, LINE - 1]}…" : line
        end

        # The record's extra counts, whole, for the hover.
        def funnel_extra(record)
          extra = breakdown(record["extra"].to_h)
          extra == "none" ? "" : " Also counted: #{extra}."
        end

        # What the stage does, as a sentence after the counts, or nothing for
        # a stage with no sentence.
        def funnel_does(stage, of_rewrite)
          sentence = StageSentences.for(stage, of_rewrite:)
          sentence ? " What it does: #{sentence}" : ""
        end

        def funnel_summary(name, record, stage, went_on = "#{Format.number(record["out"])} went on.", of_rewrite: false)
          "#{name}: #{Format.number(record["in"])} came in. " \
            "Added: #{breakdown(record["added"].to_h, rules: stage == "rewrite-rules")}. " \
            "Dropped: #{breakdown(record["dropped"].to_h, stage:)}. " \
            "Set aside: #{Format.number(record["set_aside"].to_i)}. " \
            "#{went_on}#{funnel_extra(record)}#{funnel_does(stage, of_rewrite)}"
        end
      end
    end
  end
end
