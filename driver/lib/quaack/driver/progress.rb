# frozen_string_literal: true

require "io/console"

module Quaack
  module Driver
    # Progress lines for `quaack run`, on stderr. Lines carry only step
    # names, counts, and timings, and redacted DDL the enclave already lets
    # out, never data from the enclave.
    #
    #   progress = Progress.new(io: $stderr, total: 18)
    #   progress.step("llm-index-ideas", "Asking the LLM for index ideas") { ... }
    #   # quaack: [2/18] Asking the LLM for index ideas (llm-index-ideas) 41s   on a terminal
    #   # quaack: [2/18] Done in 42s (llm-index-ideas)                 or "Failed after 42s"
    #   progress.step("llm-index-ideas", "...", summary: ->(result) { "Got 4 index ideas" }) { ... }
    #   # quaack: [2/18] Got 4 index ideas in 42s (llm-index-ideas)
    #   progress.skip("index-search", "Searching for indexes")
    #   # quaack: [1/18] Already done, skipping: Searching for indexes (index-search)
    #
    # Each line says in plain English what's happening, and ends with the
    # step's ID in parentheses. A summary must carry only counts, step
    # names, and QUAACK's own words, never anything the enclave sent as
    # text.
    #
    # note prints a line under the current step, such as an LLM ask, and
    # within(prefix) gives the same interface for a step's sub-steps, as
    # notes.
    #
    # When io is a terminal, the latest line printed while a step runs,
    # the step's own or a note, carries the step's time, counting up in
    # place: it's redrawn with \r and cleared to the end of the line about
    # once a second. A new line leaves the one before at its final
    # reading. Anywhere else, such as a log file, nothing is redrawn, and
    # only the closing line gives the time. The clock is only a duration.
    #
    # clock answers seconds and interval is the redraw's period, so specs
    # pass a fake clock and a short interval.
    class Progress
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      def initialize(io:, total:, clock: MONOTONIC, interval: 1)
        @io = io
        @tty = io.respond_to?(:tty?) && io.tty?
        @total = total
        @clock = clock
        @interval = interval
        @number = 0
        @lock = Mutex.new
      end

      # Runs the block as the next step and returns what it returns.
      # summary, if given, is called with that result, and what it returns,
      # unless nil, closes the step in place of Done.
      def step(name, description, summary: nil, &)
        @number += 1
        start = @clock.call
        result = clocked(start, "#{description} (#{name})", &)
        close("#{summary&.call(result) || "Done"} in", start, name)
        result
      rescue StandardError, Interrupt
        close("Failed after", start, name)
        raise
      end

      def skip(name, description)
        @number += 1
        say("Already done, skipping: #{description} (#{name})")
      end

      def note(text) = say(text)

      def within(prefix) = Within.new(self, prefix)

      # seconds as 42s, 1m30s, or 1h02m05s.
      def self.duration(seconds)
        seconds = seconds.to_i
        hours, rest = seconds.divmod(3600)
        minutes, secs = rest.divmod(60)
        return "#{hours}h#{format("%<m>02dm%<s>02ds", m: minutes, s: secs)}" if hours.positive?
        return "#{minutes}m#{format("%<s>02ds", s: secs)}" if minutes.positive?

        "#{secs}s"
      end

      # On a terminal, a line printed while a step runs is left open, so
      # the clock can be drawn after it. A new line ends it first.
      def say(text)
        @lock.synchronize do
          finish(@line && @start && (@clock.call - @start))
          line = "quaack: [#{@number}/#{@total}] #{text}"
          next @io.print("#{line}\n") unless @tty && @start

          @line = line
          text, @cut = fit("")
          @io.print(text)
        end
      end

      # Ends the step: the open line takes the step's time as its final
      # reading, then the closing line gives it.
      def close(words, start, name)
        @lock.synchronize do
          elapsed = @clock.call - start
          finish(elapsed)
          @io.print("quaack: [#{@number}/#{@total}] #{words} #{self.class.duration(elapsed)} (#{name})\n")
        end
      end

      # Prints line, the step's own, and runs the block as the step that
      # started at start. On a terminal, a thread redraws the clock every
      # interval; it's stopped and joined however the block ends, before
      # the closing line prints.
      def clocked(start, line)
        @lock.synchronize { @start = start }
        say(line)
        return yield unless @tty

        timer = redrawing(start, stop = Queue.new)
        yield
      ensure
        stop&.push(:stop)
        timer&.join
        @lock.synchronize { @start = nil }
      end

      def redrawing(start, stop)
        Thread.new do
          @lock.synchronize { draw(@clock.call - start) if @line } while stop.pop(timeout: @interval).nil?
        end
      end

      # Ends the open line, if any, at its final reading: elapsed, or none.
      # A line that was cut to fit, or won't fit now, is printed whole, from
      # the start of its one row, so it wraps only once it's done. Callers
      # hold the lock.
      def finish(elapsed)
        return unless @line

        suffix = elapsed && elapsed >= 1 ? " #{self.class.duration(elapsed)}" : ""
        if @cut || fit(suffix).last
          @io.print("\r#{@line}#{suffix}\e[K")
        elsif elapsed
          draw(elapsed)
        end
        @io.print("\n")
        @line = @shown = @cut = nil
      end

      # Redraws the open line with elapsed after it, once there's a whole
      # second to show and only when the reading changes. Callers hold the
      # lock.
      def draw(elapsed)
        reading = self.class.duration(elapsed)
        return if elapsed < 1 || reading == @shown

        text, @cut = fit(" #{reading}")
        @io.print("\r#{text}\e[K")
        @shown = reading
      end

      # The open line with suffix after it, as Fit cuts it for the terminal
      # now; and whether it was cut.
      def fit(suffix) = Fit.call(@line, suffix, columns)

      # The terminal's width now, or nil when it can't say.
      def columns
        width = @io.winsize[1] if @io.respond_to?(:winsize)
        width if width&.positive?
      rescue SystemCallError
        nil
      end

      private :say, :close, :clocked, :redrawing, :finish, :draw, :fit, :columns

      # Cuts a line, with suffix after it, short of width so it never
      # wraps, since \r goes back only to the start of a row. It answers the
      # text and whether it was cut. The suffix is dropped only when even a
      # bit of the line won't fit beside it. A nil width cuts nothing.
      module Fit
        module_function

        def call(line, suffix, width)
          text = "#{line}#{suffix}"
          return [text, false] if width.nil? || text.size < width

          room = width - 1 - suffix.size
          return ["#{line[0, room - 1]}…#{suffix}", true] if room >= 2

          ["#{line[0, [width - 2, 0].max]}…"[0, width - 1], true]
        end
      end

      # A step's sub-steps, printed as notes under it, each after prefix,
      # such as "Rewrite Silver Fox".
      class Within
        def initialize(progress, prefix)
          @progress = progress
          @prefix = prefix
        end

        # A sub-step prints no closing line, so it has no use for a summary.
        def step(name, description, **)
          @progress.note("#{@prefix}: #{description} (#{name})")
          yield
        end

        def skip(name, description) = @progress.note("#{@prefix}: Already done, skipping: #{description} (#{name})")

        def note(text) = @progress.note(text)

        def within(prefix) = Within.new(@progress, "#{@prefix}, #{prefix}")
      end

      # Prints nothing, for callers with no progress to show.
      module Null
        module_function

        def step(*, **) = yield

        def skip(*) = nil

        def note(*) = nil

        def within(*) = self
      end

      NULL = Null
    end
  end
end
