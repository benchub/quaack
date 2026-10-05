# frozen_string_literal: true

require "erb"
require "pg_query"

module Quaack
  module Driver
    module Report
      # How the report writes a number, a size, and a query.
      #
      # SQL inside a sentence, such as an index's columns or a table's name,
      # is marked with sql_span, so the words around it can stay plain text.
      # h escapes the text, then sets each marked piece in a <code
      # class="sql">. The marks are control characters, and View drops them
      # from the payload with unmarked before it says anything, so a value
      # can't open or close a piece of its own.
      #
      #   h("on #{sql_span("public.t (a < 1)")}")  # => %(on <code class="sql">public.t (a &lt; 1)</code>)
      module Format
        UNITS = %w[kB MB GB].freeze
        PRETTY = { pretty_print: true, indent_size: 2, max_line_length: 80, trailing_newline: false }.freeze
        OPEN = "\u0001"
        CLOSE = "\u0002"
        MARKS = "#{OPEN}#{CLOSE}".freeze
        MARKED = /#{OPEN}([^#{MARKS}]*)#{CLOSE}/

        module_function

        def h(value) = ERB::Util.html_escape(value.to_s).gsub(MARKED, '<code class="sql">\\1</code>')

        # SQL, marked to be set apart wherever h prints it.
        def sql_span(text) = "#{OPEN}#{text}#{CLOSE}"

        # A value with no marks in any String it holds, keys included.
        def unmarked(value)
          case value
          when String then value.delete(MARKS)
          when Hash then value.to_h { |k, v| [unmarked(k), unmarked(v)] }
          when Array then value.map { unmarked(it) }
          else value
          end
        end

        # An Integer with thousands separators. Anything else as it is.
        def number(value)
          return value.to_s unless value.is_a?(Integer)

          value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse.prepend(value.negative? ? "-" : "")
        end

        # Bytes in the unit that fits: whole kB, or MB or GB to one decimal.
        def size(bytes)
          return Words::MISSING unless bytes.is_a?(Integer)

          kilobytes = bytes / 1024.0
          return "#{number(kilobytes.round)} kB" if kilobytes.round < 1024

          megabytes = kilobytes / 1024
          megabytes.round(1) < 1024 ? decimal(megabytes, "MB") : decimal(megabytes / 1024, "GB")
        end

        def decimal(value, unit)
          whole, tenth = format("%.1f", value).split(".")
          "#{number(whole.to_i)}.#{tenth} #{unit}"
        end

        # A candidate's blocks against your query's, such as "52% fewer
        # blocks", or nil when either is missing.
        def against(ours, theirs)
          return unless ours && theirs
          return "same" if ours == theirs
          return "#{number(ours)} more #{ours == 1 ? "block" : "blocks"}" if theirs.zero?

          "#{apart(ours, theirs)}% #{ours < theirs ? "fewer" : "more"} blocks"
        end

        # How many percent of theirs ours is away from it, never rounded to
        # no difference or to all of it.
        def apart(ours, theirs)
          percent = ((ours - theirs).abs * 100.0 / theirs).round
          return "under 1" if percent.zero?
          return "over 99" if percent == 100 && ours.positive? && ours < theirs

          number(percent)
        end

        # The query laid out over several lines by pg_query, which keeps $n
        # placeholders and clock functions. SQL it can't lay out (it doesn't parse, say) is
        # shown as it was sent.
        def sql(text)
          PgQuery.deparse(PgQuery.parse(text.to_s).tree, opts: PgQuery::DeparseOpts.new(**PRETTY))
        rescue StandardError
          text.to_s
        end
      end
    end
  end
end
