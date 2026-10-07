# frozen_string_literal: true

require "io/console"
require_relative "quiet_stream"

module Quaack
  module Driver
    # Progress lines for `quaack run`, on stderr. Lines carry only step
    # names, counts, and timings, and redacted DDL the enclave already lets
    # out, never data from the enclave.
    #
    #   progress = Progress.new(io: $stderr, total: 18)
    #   progress.step("index-rank", "Ranking the index ideas") { ... }
    #   # quaack: [2/18] Ranking the index ideas (index-rank) 42s   on a terminal, and no more
    #   # quaack: [2/18] Done in 42s (index-rank)                    elsewhere, after the line above
    #   #                                                           without its clock
    #   # quaack: [2/18] Failed after 42s (index-rank)               if it fails, anywhere
    #   progress.step("llm-index-ideas", "...", summary: ->(result) { "Got 4 index ideas" }, informative: true) { ... }
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
    # step_note(name, text) one that ends with the step's ID, such as an
    # enclave call the step makes between LLM asks. within(prefix) gives the
    # same interface for a step's sub-steps, as notes.
    #
    # When io is a terminal, the latest line printed while a step runs,
    # the step's own or a note, carries the step's time, counting up in
    # place: about once a second, it goes back with \r, clears the row
    # with \e[K, and is drawn again. Clearing first matters when a line
    # fills the row: the cursor then waits on the last column, and a
    # clear there would erase the last character. A new line leaves the
    # one before at its final reading. Anywhere else, such as a log file,
    # nothing is redrawn, and only the closing line gives the time. The
    # clock is only a duration.
    #
    # On a terminal, it leaves out what the clock makes redundant. A step
    # that would close with a bare Done, or with a summary the step doesn't
    # flag as informative, such as "Ranked the index ideas", prints no
    # closing line: its last open line ends at the step's final reading,
    # even 0s. And a note that says no more than the step's own line, such
    # as an LLM ask's "Asking the LLM (llm-rewrites)" under "Asking the LLM
    # for rewrites of the query (llm-rewrites)", isn't printed while the
    # clock is on that line, and nor is one that says no more than the
    # current sub-step's line after its prefix, whatever its ID. When a note
    # came between, such as "Reading the query's shape for the LLM", a short
    # line, "Waiting for the LLM" and the ask's ID, prints in its place, so
    # the clock leaves the note and the wait isn't read as the note's. A
    # repeat right after that wait isn't printed either. An informative
    # summary's closing line, a failed line, and a note that adds
    # something, such as a retry or an ask again, still print.
    #
    # Progress is only for show, so losing io doesn't stop the run. The
    # first write that fails, such as to a pipe whose reader has closed,
    # ends the progress lines quietly, the clock's redraws with them, and
    # every step still runs to its own result or exception (QuietStream).
    #
    # clock answers seconds and interval is the redraw's period, so specs
    # pass a fake clock and a short interval.
    class Progress
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      def initialize(io:, total:, clock: MONOTONIC, interval: 1)
        @io = QuietStream.wrap(io)
        @tty = io.respond_to?(:tty?) && io.tty?
        @total = total
        @clock = clock
        @interval = interval
        @number = 0
        @lock = Mutex.new
      end

      # Runs the block as the next step and returns what it returns.
      # summary, if given, is called with that result, and what it returns,
      # unless nil, closes the step in place of Done. On a terminal, it's
      # left out unless informative, the step's flag that it carries more
      # than the step's own line, such as counts.
      def step(name, description, summary: nil, informative: false, &)
        @number += 1
        start = @clock.call
        result = clocked(start, description, name, &)
        summary = nil if @tty && !informative
        close(summary&.call(result)&.then { "#{it} in" }, start, name)
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

      def step_note(name, text) = say("#{text} (#{name})")

      def within(prefix) = Within.new(self, prefix)

      # Runs the block as a sub-step of the current step, if any, whose line
      # says description, so on a terminal a note that repeats it is left
      # out, or prints as a wait line if another note came between
      # (repeats_step?, Repeat#shown).
      def sub_step(description, &) = @own ? @own.within(description, &) : yield

      # seconds as 42s, 1m30s, or 1h02m05s.
      def self.duration(seconds) = Duration.call(seconds)

      # On a terminal, a line printed while a step runs is left open, so
      # the clock can be drawn after it. A new line ends it first.
      def say(text)
        @lock.synchronize do
          next unless (text = shown(text))

          finish(@line && @start && (@clock.call - @start))
          line = "quaack: [#{@number}/#{@total}] #{text}"
          next @io.print("#{line}\n") unless @tty && @start

          @line = line
          text, @cut = fit("")
          @io.print(text)
        end
      end

      # On a terminal, whether text, a line under the step, says no more
      # than the step's own line, or the current sub-step's, however many
      # lines came after it (Repeat). Only an LLM ask's note does today,
      # so the check needn't tell a note from a step_note. Callers hold
      # the lock.
      def repeats_step?(text) = @tty && @own&.repeated?(text)

      # text as it prints, or nil if it's left out (Repeat#shown). Callers
      # hold the lock.
      def shown(text) = @own ? @own.shown(text, repeats_step?(text)) : text

      # Ends the step: the open line takes the step's time as its final
      # reading, then the closing line, words and the time, gives it. With
      # no words, it closes with Done, but on a terminal prints no closing
      # line, since the open line's final reading already gives the time.
      def close(words, start, name)
        @lock.synchronize do
          elapsed = @clock.call - start
          next finish(elapsed, final: true) if words.nil? && @tty

          finish(elapsed)
          @io.print("quaack: [#{@number}/#{@total}] #{words || "Done in"} #{self.class.duration(elapsed)} (#{name})\n")
        end
      end

      # Prints the step's own line, description and name, and runs the
      # block as the step that started at start. On a terminal, a thread
      # redraws the clock every interval; it's stopped and joined however
      # the block ends, before the closing line prints.
      def clocked(start, description, name)
        @lock.synchronize { @start = start }
        say("#{description} (#{name})")
        @own = Repeat.new(description, name)
        return yield unless @tty

        timer = redrawing(start, stop = Queue.new)
        yield
      ensure
        stopping(stop, timer)
      end

      # Stops and joins the timer, if any, and ends the step's clock, even
      # if Ctrl-C comes during the join.
      def stopping(stop, timer)
        stop&.push(:stop)
        timer&.join
      ensure
        @lock.synchronize { @start = @own = nil }
      end

      def redrawing(start, stop)
        Thread.new do
          @lock.synchronize { draw(@clock.call - start) if @line } while stop.pop(timeout: @interval).nil?
        end
      end

      # Ends the open line, if any, at its final reading: elapsed, or none.
      # Under a second it shows none, unless final, for a line that must
      # give the step's time as it closes. A line that was cut to fit, or
      # won't fit now, is printed whole, from the start of its one row, so
      # it wraps only once it's done. Callers hold the lock.
      def finish(elapsed, final: false)
        return unless @line

        reading = final_reading(elapsed, final)
        suffix = " #{reading}" if reading
        @io.print("\r\e[K#{@line}#{suffix}") if @cut || fit(suffix.to_s).last || (reading && reading != @shown)
        @io.print("\n")
        @line = @shown = @cut = nil
      end

      # elapsed as the open line's final reading, or nil for none.
      def final_reading(elapsed, final) = (self.class.duration(elapsed) if elapsed && (final || elapsed >= 1))

      # Redraws the open line with elapsed after it, once there's a whole
      # second to show and only when the reading changes. Callers hold the
      # lock.
      def draw(elapsed)
        reading = self.class.duration(elapsed)
        return if elapsed < 1 || reading == @shown

        text, @cut = fit(" #{reading}")
        @io.print("\r\e[K#{text}")
        @shown = reading
      end

      # The open line with suffix after it, as Fit cuts it for the terminal
      # now; and whether it was cut.
      def fit(suffix) = Fit.call(@line, suffix, Fit.columns(@io))

      private :say, :repeats_step?, :shown, :close, :clocked, :stopping, :redrawing, :finish, :final_reading, :draw,
              :fit

      # seconds as 42s, 1m30s, or 1h02m05s (Progress.duration).
      module Duration
        module_function

        def call(seconds)
          seconds = seconds.to_i
          hours, rest = seconds.divmod(3600)
          minutes, secs = rest.divmod(60)
          return "#{hours}h#{format("%<m>02dm%<s>02ds", m: minutes, s: secs)}" if hours.positive?
          return "#{minutes}m#{format("%<s>02ds", s: secs)}" if minutes.positive?

          "#{secs}s"
        end
      end

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

        # io's terminal width now, or nil when it can't say.
        def columns(io)
          width = io.winsize[1] if io.respond_to?(:winsize)
          width if width&.positive?
        rescue SystemCallError
          nil
        end
      end

      # The lines a note under a step mustn't merely repeat: the step's
      # own, and its current sub-step's, if any. It's made once the step's
      # own line has printed, so that line is the latest, @plain.
      class Repeat
        def initialize(description, name)
          @lines = [[description, name]]
          @plain = true
        end

        # Runs the block as a sub-step whose line says description, the
        # latest line once the block starts.
        def within(description)
          @plain = true
          @lines.push([description])
          yield
        ensure
          @lines.pop
        end

        def repeated?(text) = @lines.any? { |description, name| self.class.call(text, description, name) }

        # text as it prints after the latest line, or nil if it's left out.
        # A note that repeats a line, repeat, is left out while that line or
        # a wait is the latest, @plain, and so keeps the clock. After any
        # other line, it prints as a short wait with its ID, so the clock
        # leaves that line, and the LLM's time isn't read as its.
        def shown(text, repeat)
          return if repeat && @plain

          @plain = repeat
          repeat ? text.sub(/\A.* (?=\([^()]+\)\z)/, "Waiting for the LLM ") : text
        end

        # Whether a note, text, says no more than a line: it ends with the
        # line's ID, name, and what comes before is the line's description
        # or its first words, as an LLM ask's "Asking the LLM
        # (llm-rewrites)" does under "Asking the LLM for rewrites of the
        # query (llm-rewrites)". With no name, as for a sub-step, any ID will
        # do, since its ask names the LLM's step, such as
        # llm-counterexamples under counterexamples.
        def self.call(text, description, name = nil)
          words = name ? text.delete_suffix(" (#{name})") : text.sub(/ \([^()]+\)\z/, "")
          words != text && (description == words || description.start_with?("#{words} "))
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
        def step(name, description, **, &)
          @progress.note("#{@prefix}: #{description} (#{name})")
          @progress.sub_step(description, &)
        end

        def skip(name, description) = @progress.note("#{@prefix}: Already done, skipping: #{description} (#{name})")

        def note(text) = @progress.note(text)

        def step_note(name, text) = @progress.note("#{@prefix}: #{text} (#{name})")

        def within(prefix) = Within.new(@progress, "#{@prefix}, #{prefix}")
      end

      # Prints nothing, for callers with no progress to show.
      module Null
        module_function

        def step(*, **) = yield

        def skip(*) = nil

        def note(*) = nil

        def step_note(*) = nil

        def within(*) = self
      end

      NULL = Null
    end
  end
end
