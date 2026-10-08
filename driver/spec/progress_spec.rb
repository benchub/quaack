# frozen_string_literal: true

require "stringio"
require "quaack/driver/progress"

# Each line says in plain English what's happening, with the step's ID in
# parentheses at the end.
RSpec.describe Quaack::Driver::Progress do
  let(:io) { StringIO.new }
  let(:times) { [0.0] }
  # A clock that reads each queued time in turn, then keeps the last.
  let(:clock) { -> { times.size > 1 ? times.shift : times.first } }

  def progress(total: 3, interval: 30) = described_class.new(io:, total:, clock:, interval:)

  it "prints a numbered start line and a done line with the step's time" do
    times.replace([0.0, 42.4])
    result = progress.step("llm-index-ideas", "Asking the LLM for index ideas") { :value }

    expect(result).to eq(:value)
    expect(io.string).to eq("quaack: [1/3] Asking the LLM for index ideas (llm-index-ideas)\n" \
                            "quaack: [1/3] Done in 42s (llm-index-ideas)\n")
  end

  describe "a step's summary" do
    let(:summary) { ->(result) { "Found #{result.size} possible index definitions mechanically" } }

    it "closes the step with its summary of the step's result, then its time" do
      times.replace([0.0, 15.0])
      result = progress.step("index-search", "Searching for indexes", summary:) { %w[a b c] }

      expect(result).to eq(%w[a b c])
      expect(io.string.lines.last)
        .to eq("quaack: [1/3] Found 3 possible index definitions mechanically in 15s (index-search)\n")
    end

    it "closes with Done when the summary gives none" do
      times.replace([0.0, 2.0])
      progress.step("index-rank", "Ranking", summary: ->(_) {}) { :ranked }

      expect(io.string.lines.last).to eq("quaack: [1/3] Done in 2s (index-rank)\n")
    end

    it "closes a failed step with its failed line, without a summary" do
      times.replace([0.0, 3.0])
      expect { progress.step("llm-rewrites", "Asking", summary:) { raise "boom" } }.to raise_error("boom")

      expect(io.string.lines.last).to eq("quaack: [1/3] Failed after 3s (llm-rewrites)\n")
    end

    it "is taken, and ignored, by sub-steps and NULL, which print no closing line" do
      p = progress
      p.step("plan-pruning", "Searching") do
        expect(p.within("Rewrite 1").step("index-search", "Searching", summary:) { :ran }).to eq(:ran)
      end
      expect(described_class::NULL.step("a", "b", summary:) { 7 }).to eq(7)

      expect(io.string.lines.size).to eq(3)
      expect(io.string).not_to include("Found")
    end
  end

  it "numbers each step and skip in turn, and prints a skip line that says what's skipped" do
    p = progress
    p.skip("index-search", "Searching for indexes")
    p.step("llm-index-ideas", "Asking the LLM for index ideas") { nil }

    expect(io.string.lines.first).to eq("quaack: [1/3] Already done, skipping: Searching for indexes (index-search)\n")
    expect(io.string.lines[1]).to eq("quaack: [2/3] Asking the LLM for index ideas (llm-index-ideas)\n")
  end

  it "prints notes under the current step" do
    p = progress
    p.step("llm-rewrites", "Asking the LLM for rewrites") { p.note("Asking the LLM (llm-rewrites)") }

    expect(io.string.lines[1]).to eq("quaack: [1/3] Asking the LLM (llm-rewrites)\n")
  end

  it "prints a step's note with the step's ID in parentheses, unnumbered" do
    p = progress
    p.step("llm-rewrites", "Asking the LLM for rewrites") { p.step_note("llm-rewrites", "Checking the LLM's rewrites") }

    expect(io.string.lines[1]).to eq("quaack: [1/3] Checking the LLM's rewrites (llm-rewrites)\n")
    expect(io.string.lines.last).to start_with("quaack: [1/3] Done")
  end

  it "prints minutes and hours in times" do
    times.replace([0.0, 90.0])
    p = progress
    p.step("a", "a") { nil }
    times.replace([0.0, 3725.0])
    p.step("b", "b") { nil }

    expect(io.string.lines.grep(/Done/)).to eq(["quaack: [1/3] Done in 1m30s (a)\n",
                                                "quaack: [2/3] Done in 1h02m05s (b)\n"])
  end

  it "prints a failed line with the time, and re-raises, when the step raises" do
    times.replace([0.0, 3.0])
    expect { progress.step("llm-rewrites", "Asking the LLM for rewrites") { raise "boom" } }.to raise_error("boom")
    expect(io.string.lines.last).to eq("quaack: [1/3] Failed after 3s (llm-rewrites)\n")
  end

  describe "the live clock" do
    # A terminal, as far as Progress can tell.
    let(:terminal) { Class.new(StringIO) { def tty? = true }.new }
    let(:now) { [0.0] }
    let(:live) { described_class.new(io: terminal, total: 3, clock: -> { now.first }, interval: 0.005) }

    # Waits, briefly, until out holds text.
    def wait_for(out, text)
      400.times { out.string.include?(text) ? break : sleep(0.005) }
      expect(out.string).to include(text)
    end

    it "counts up in place on the latest line, which keeps its final reading under a new line" do
      before = Thread.list.size
      live.step("llm-rewrites", "Asking the LLM for rewrites of the query") do
        live.note("Asking the LLM (llm-rewrites)")
        now[0] = 1.2
        wait_for(terminal, "(llm-rewrites) 1s")
        sleep(0.05) # many redraws' time, at the same reading
        now[0] = 61.0
        wait_for(terminal, "(llm-rewrites) 1m01s")
        now[0] = 65.0
        live.note("Asking the LLM, attempt 2 (llm-rewrites)")
        now[0] = 70.0
      end

      expect(terminal.string).to eq(
        "quaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites)" \
        "\r\e[Kquaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites) 1s" \
        "\r\e[Kquaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites) 1m01s" \
        "\r\e[Kquaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites) 1m05s\n" \
        "quaack: [1/3] Asking the LLM, attempt 2 (llm-rewrites)" \
        "\r\e[Kquaack: [1/3] Asking the LLM, attempt 2 (llm-rewrites) 1m10s\n"
      )
      expect(Thread.list.size).to eq(before)
    end

    it "puts no clock on a line that ends within the step's first second, and ends whole lines between steps" do
      live.skip("index-search", "Searching for indexes")
      live.step("llm-index-ideas", "Asking the LLM for index ideas") do
        live.note("Testing the index ideas (index-test)")
        now[0] = 0.4
        live.note("Testing again (index-test)")
      end
      live.note("Between steps")

      expect(terminal.string).to eq(
        "quaack: [1/3] Already done, skipping: Searching for indexes (index-search)\n" \
        "quaack: [2/3] Asking the LLM for index ideas (llm-index-ideas)\n" \
        "quaack: [2/3] Testing the index ideas (index-test)\n" \
        "quaack: [2/3] Testing again (index-test)\r\e[Kquaack: [2/3] Testing again (index-test) 0s\n" \
        "quaack: [2/3] Between steps\n"
      )
    end

    it "stops redrawing when a step fails, so nothing lands after its failed line" do
      before = Thread.list.size
      expect do
        live.step("llm-rewrites", "Asking") do
          now[0] = 2.0
          wait_for(terminal, "(llm-rewrites) 2s")
          now[0] = 3.0
          raise "boom"
        end
      end.to raise_error("boom")
      ended = terminal.string.dup
      now[0] = 9.0
      sleep(0.05)

      expect(terminal.string).to eq(ended)
      expect(ended).to end_with("Asking (llm-rewrites) 3s\nquaack: [1/3] Failed after 3s (llm-rewrites)\n")
      expect(Thread.list.size).to eq(before)
    end

    it "stops redrawing when a step is interrupted, too" do
      before = Thread.list.size
      expect { live.step("llm-rewrites", "Asking") { raise Interrupt } }.to raise_error(Interrupt)
      ended = terminal.string.dup
      now[0] = 9.0
      sleep(0.05)

      expect(terminal.string)
        .to eq("quaack: [1/3] Asking (llm-rewrites)\nquaack: [1/3] Failed after 0s (llm-rewrites)\n")
      expect(terminal.string).to eq(ended)
      expect(Thread.list.size).to eq(before)
    end

    describe "its timer thread" do
      # A terminal that calls hook, if set, with each print's text before
      # printing it, in the thread that prints.
      let(:hooked) do
        Class.new(StringIO) do
          attr_accessor :hook

          def tty? = true

          def print(*args)
            hook&.call(args.join)
            super
          end
        end.new
      end

      # Waits, without a race, until thread is asleep, or fails after a
      # while so a broken spec can't hang.
      def wait_until_asleep(thread)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until thread.status == "sleep"
          raise "#{thread.inspect} never slept" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          Thread.pass
        end
      end

      it "finishes its last redraw before the next step's line opens, so it never draws a stale time there" do
        # With no interval, the timer never sleeps on its queue, only when
        # it waits for the lock.
        p = described_class.new(io: hooked, total: 3, clock: -> { now.first }, interval: 0)
        before = Thread.list
        timer = nil
        # The note's print holds the step's thread, and the lock, until the
        # timer has woken for a redraw and waits for the lock. The redraw
        # then comes as the step closes.
        hooked.hook = lambda do |text|
          next unless text.include?("Noting (a)")

          hooked.hook = nil
          wait_until_asleep(timer)
        end
        p.step("a", "A") do
          timer, = Thread.list - before
          now[0] = 5.0
          p.note("Noting (a)")
        end
        # Lets a timer still running from step a take its redraw.
        p.step("b", "B") { timer.join }

        expect(hooked.string).to eq(
          "quaack: [1/3] A (a)\r\e[Kquaack: [1/3] A (a) 5s\n" \
          "quaack: [1/3] Noting (a)\r\e[Kquaack: [1/3] Noting (a) 5s\n" \
          "quaack: [2/3] B (b)\r\e[Kquaack: [2/3] B (b) 0s\n"
        )
        expect(Thread.list).to eq(before)
      end

      it "still ends the step's clock when Ctrl-C comes while the step waits for the timer" do
        p = described_class.new(io: hooked, total: 3, clock: -> { now.first }, interval: 0.001)
        stepper = Thread.current
        drawing = Queue.new
        drawn = Queue.new
        # The timer's redraw is held mid-draw, with the lock, so the step
        # waits for the timer as it ends.
        hooked.hook = lambda do |text|
          next unless Thread.current != stepper && text.include?(" 2s")

          hooked.hook = nil
          drawing.push(true)
          drawn.pop
        end
        ctrl_c = nil
        expect do
          p.step("a", "A") do
            now[0] = 2.0
            drawing.pop
            ctrl_c = Thread.new do
              wait_until_asleep(stepper)
              stepper.raise(Interrupt)
              drawn.push(true)
            end
          end
        end.to raise_error(Interrupt)
        ctrl_c.join
        p.note("Between steps")

        expect(hooked.string).to eq(
          "quaack: [1/3] A (a)\r\e[Kquaack: [1/3] A (a) 2s\n" \
          "quaack: [1/3] Failed after 2s (a)\n" \
          "quaack: [1/3] Between steps\n"
        )
      end

      describe "when a redraw fails to write" do
        let(:broken) do
          p = described_class.new(io: hooked, total: 3, clock: -> { now.first }, interval: 0.001)
          stepper = Thread.current
          signal = failed
          hooked.hook = lambda do |_text|
            next if Thread.current == stepper

            signal.push(true)
            raise Errno::EPIPE
          end
          p
        end
        let(:failed) { Queue.new }

        def redraw_fails
          now[0] = 2.0
          failed.pop
        end

        it "keeps the step's own result, and prints nothing more" do
          before = Thread.list.size
          result = broken.step("a", "A") { redraw_fails.then { :value } }
          broken.step("b", "B") { now[0] = 9.0 }

          expect(result).to eq(:value)
          expect(hooked.string).to eq("quaack: [1/3] A (a)")
          expect(Thread.list.size).to eq(before)
        end

        it "keeps the step's own exception" do
          expect { broken.step("a", "A") { redraw_fails.then { raise "boom" } } }.to raise_error("boom")

          expect(hooked.string).to eq("quaack: [1/3] A (a)")
        end
      end
    end

    describe "on a narrow terminal" do
      # A terminal whose width can change, as a resized window's does.
      let(:narrow) do
        Class.new(StringIO) do
          attr_accessor :columns

          def tty? = true

          def winsize = [24, columns]
        end.new
      end
      let(:fitted) { described_class.new(io: narrow, total: 3, clock: -> { now.first }, interval: 0.005) }

      it "cuts the open line to fit, clock and all, and prints it whole when it ends" do
        narrow.columns = 40
        fitted.step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
          now[0] = 70.0
          wait_for(narrow, " 1m10s")
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM for index…" \
          "\r\e[Kquaack: [1/3] Asking the LLM for… 1m10s" \
          "\r\e[Kquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas) 1m10s\n"
        )
      end

      it "cuts a line only once its clock won't fit, and reads the width at each redraw" do
        narrow.columns = 46
        fitted.step("llm-rewrites", "Asking the LLM") do
          now[0] = 1.2
          wait_for(narrow, " 1s")
          narrow.columns = 80
          now[0] = 61.0
          wait_for(narrow, " 1m01s")
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM (llm-rewrites)" \
          "\r\e[Kquaack: [1/3] Asking the LLM (llm-rewrite… 1s" \
          "\r\e[Kquaack: [1/3] Asking the LLM (llm-rewrites) 1m01s\n"
        )
      end

      it "prints a cut line whole when it ends, even once the terminal is wide enough for it" do
        narrow.columns = 40
        fitted.step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
          narrow.columns = 200
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM for index…" \
          "\r\e[Kquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas) 0s\n"
        )
      end

      it "prints a line a redraw cut whole when it ends, even if the window widened since, at the same reading" do
        narrow.columns = 36
        fitted.step("llm-rewrites", "Asking") do
          now[0] = 1.2
          wait_for(narrow, "… 1s")
          narrow.columns = 80
          now[0] = 1.5
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking (llm-rewrites)" \
          "\r\e[Kquaack: [1/3] Asking (llm-rewri… 1s" \
          "\r\e[Kquaack: [1/3] Asking (llm-rewrites) 1s\n"
        )
      end

      # One terminal width columns wide, as xterm draws: a character in the
      # last column leaves the cursor on it, waiting to wrap, so a \e[K
      # there erases that character. rows is what it shows.
      let(:xterm) do
        Class.new do
          attr_reader :rows

          def initialize(width)
            @width = width
            @rows = [+""]
            @col = 0
          end

          def feed(bytes)
            bytes.scan(/\e\[K|./m) { |token| control?(token) || put(token) }
            self
          end

          def control?(token)
            case token
            when "\r" then @col = 0
            when "\n" then newline
            when "\e[K" then @rows.last.slice!(@col..)
            else return false
            end
            @wrap = false
            true
          end

          def put(char)
            newline if @wrap
            @rows.last[@col] = char
            @wrap = @col == @width - 1
            @col += 1 unless @wrap
          end

          def newline
            @rows << +""
            @col = 0
          end
        end
      end

      it "keeps the last character of a finished line exactly as wide as the terminal" do
        narrow.columns = 41
        slow = described_class.new(io: narrow, total: 3, clock: -> { now.first }, interval: 60)
        slow.step("llm-rewrites", "Asking") { now[0] = 62.0 }

        expect(xterm.new(41).feed(narrow.string).rows).to eq(["quaack: [1/3] Asking (llm-rewrites) 1m02s", ""])
      end

      it "prints a line whole when it ends, if its final reading won't fit beside it" do
        narrow.columns = 46
        slow = described_class.new(io: narrow, total: 3, clock: -> { now.first }, interval: 60)
        slow.step("llm-rewrites", "Asking the LLM") { now[0] = 1.2 }

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM (llm-rewrites)" \
          "\r\e[Kquaack: [1/3] Asking the LLM (llm-rewrites) 1s\n"
        )
      end

      it "keeps within a terminal too narrow for the clock" do
        narrow.columns = 5
        fitted.step("llm-rewrites", "Asking") do
          now[0] = 2.0
          wait_for(narrow, "\r")
        end

        expect(narrow.string).to eq("qua…\r\e[Kqua…\r\e[Kquaack: [1/3] Asking (llm-rewrites) 2s\n")
      end

      it "doesn't cut when the terminal can't say its width" do
        unsized = Class.new(StringIO) do
          def tty? = true

          def winsize = raise(Errno::ENOTTY)
        end.new
        zero = Class.new(StringIO) do
          def tty? = true

          def winsize = [0, 0]
        end.new
        [unsized, zero].each do |out|
          now[0] = 0.0
          described_class.new(io: out, total: 3, clock: -> { now.first }, interval: 0.005)
                         .step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
            now[0] =
              2.0
          end

          expect(out.string).to eq(
            "quaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)" \
            "\r\e[Kquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas) 2s\n"
          )
        end
      end
    end

    describe "lines the clock makes redundant" do
      it "prints no Done line, and leaves the open line at the step's final reading, even under a second" do
        live.step("index-rank", "Ranking the index ideas") { now[0] = 2.0 }
        live.step("arena-setup", "Setting up the arena") { now[0] = 2.4 }
        live.note("Setting up the arena (arena-setup)")

        expect(terminal.string).to eq(
          "quaack: [1/3] Ranking the index ideas (index-rank)" \
          "\r\e[Kquaack: [1/3] Ranking the index ideas (index-rank) 2s\n" \
          "quaack: [2/3] Setting up the arena (arena-setup)" \
          "\r\e[Kquaack: [2/3] Setting up the arena (arena-setup) 0s\n" \
          "quaack: [2/3] Setting up the arena (arena-setup)\n"
        )
      end

      it "freezes the last note at the step's final reading when a step without a summary ends" do
        live.step("plan-pruning", "Searching for indexes for each rewrite") do
          now[0] = 3.0
          live.within("Rewrite Silver Fox").step("rewrite-prune", "Dropping the rewrite") { now[0] = 5.0 }
        end

        expect(terminal.string).to eq(
          "quaack: [1/3] Searching for indexes for each rewrite (plan-pruning)" \
          "\r\e[Kquaack: [1/3] Searching for indexes for each rewrite (plan-pruning) 3s\n" \
          "quaack: [1/3] Rewrite Silver Fox: Dropping the rewrite (rewrite-prune)" \
          "\r\e[Kquaack: [1/3] Rewrite Silver Fox: Dropping the rewrite (rewrite-prune) 5s\n"
        )
      end

      it "prints no closing line for a summary not flagged as informative, which only repeats the step" do
        live.step("index-rank", "Ranking the index ideas", summary: ->(_) { "Ranked the index ideas" }) do
          now[0] = 5.0
        end

        expect(terminal.string).to eq(
          "quaack: [1/3] Ranking the index ideas (index-rank)" \
          "\r\e[Kquaack: [1/3] Ranking the index ideas (index-rank) 5s\n"
        )
      end

      it "still closes a step with its summary when the step flags it as informative" do
        live.step("llm-rewrites", "Asking the LLM for rewrites of the query",
                  summary: ->(n) { "Got #{n} rewrites from the LLM" }, informative: true) do
          now[0] = 0.5
          3
        end

        expect(terminal.string).to eq(
          "quaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites)\n" \
          "quaack: [1/3] Got 3 rewrites from the LLM in 0s (llm-rewrites)\n"
        )
      end

      it "still prints a failed line" do
        expect { live.step("index-rank", "Ranking") { raise "boom" } }.to raise_error("boom")

        expect(terminal.string)
          .to eq("quaack: [1/3] Ranking (index-rank)\nquaack: [1/3] Failed after 0s (index-rank)\n")
      end

      it "leaves out a step's only LLM ask when its note says no more than the step's own line" do
        live.step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
          live.note("Asking the LLM for index ideas (llm-index-ideas)")
          now[0] = 32.0
        end
        live.step("llm-rewrites", "Asking the LLM for rewrites of the query") do
          live.note("Asking the LLM (llm-rewrites)")
          now[0] = 83.0
        end

        expect(terminal.string).to eq(
          "quaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)" \
          "\r\e[Kquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas) 32s\n" \
          "quaack: [2/3] Asking the LLM for rewrites of the query (llm-rewrites)" \
          "\r\e[Kquaack: [2/3] Asking the LLM for rewrites of the query (llm-rewrites) 51s\n"
        )
      end

      it "prints a short wait in place of an ask that repeats the step after a note, so the clock leaves the note" do
        live.step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
          live.step_note("llm-index-ideas", "Reading the query's shape for the LLM")
          now[0] = 2.0
          live.note("Asking the LLM for index ideas (llm-index-ideas)")
          now[0] = 30.0
        end

        expect(terminal.string.split("\n")).to eq(
          ["quaack: [1/3] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas)",
           "quaack: [1/3] Reading the query's shape for the LLM (llm-index-ideas)" \
           "\r\e[Kquaack: [1/3] Reading the query's shape for the LLM (llm-index-ideas) 2s",
           "quaack: [1/3] Waiting for the LLM (llm-index-ideas)" \
           "\r\e[Kquaack: [1/3] Waiting for the LLM (llm-index-ideas) 30s"]
        )
      end

      it "prints every ask after a note whole when stderr isn't a terminal" do
        logged = progress
        logged.step("llm-index-ideas", "Asking the LLM for index ideas the mechanical search missed") do
          logged.step_note("llm-index-ideas", "Reading the query's shape for the LLM")
          logged.note("Asking the LLM for index ideas (llm-index-ideas)")
        end

        expect(io.string.split("\n")[2]).to eq("quaack: [1/3] Asking the LLM for index ideas (llm-index-ideas)")
      end

      it "leaves out a second ask identical to the first right after it, and waits on a short line after a note" do
        live.step("llm-rewrites", "Asking the LLM for rewrites of the query") do
          live.note("Asking the LLM (llm-rewrites)")
          live.note("Asking the LLM (llm-rewrites)")
          now[0] = 4.0
          live.step_note("llm-rewrites", "Checking the LLM's rewrites")
          now[0] = 6.0
          live.note("Asking the LLM (llm-rewrites)")
          live.note("Asking the LLM (llm-rewrites)")
          now[0] = 9.0
        end

        expect(terminal.string.split("\n")).to eq(
          ["quaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites)" \
           "\r\e[Kquaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites) 4s",
           "quaack: [1/3] Checking the LLM's rewrites (llm-rewrites)" \
           "\r\e[Kquaack: [1/3] Checking the LLM's rewrites (llm-rewrites) 6s",
           "quaack: [1/3] Waiting for the LLM (llm-rewrites)" \
           "\r\e[Kquaack: [1/3] Waiting for the LLM (llm-rewrites) 9s"]
        )
      end

      it "keeps an ask whose words only start like the step's, not at a word's end" do
        live.step("llm-index-ideas", "Asking the LLM for index ideas") do
          live.note("Asking the LLM for index idea (llm-index-ideas)")
        end

        expect(terminal.string.split("\n").last)
          .to start_with("quaack: [1/3] Asking the LLM for index idea (llm-index-ideas)")
      end

      it "leaves out an ask that repeats a sub-step's words right after the sub-step's line, whatever its ID" do
        live.step("rewrite-correctness", "Testing each rewrite for wrong results") do
          sub = live.within("Rewrite Silver Fox")
          sub.step("counterexamples", "Asking the LLM for rows that could break the rewrite") do
            live.note("Asking the LLM for rows that could break the rewrite (llm-counterexamples)")
          end
        end

        expect(terminal.string.split("\n").map { it[/\A[^\r]*/] }).to eq(
          ["quaack: [1/3] Testing each rewrite for wrong results (rewrite-correctness)",
           "quaack: [1/3] Rewrite Silver Fox: Asking the LLM for rows that could break the rewrite (counterexamples)"]
        )
      end

      it "keeps an ask that names its provider, under a step or a sub-step, since the name adds something" do
        live.step("llm-rewrites", "Asking the LLM for rewrites of the query") do
          live.note("Asking the LLM (llm-rewrites, groq)")
        end
        live.step("rewrite-correctness", "Testing each rewrite for wrong results") do
          sub = live.within("Rewrite Silver Fox")
          sub.step("counterexamples", "Asking the LLM for rows that could break the rewrite") do
            live.note("Asking the LLM for rows that could break the rewrite (llm-counterexamples, opus)")
          end
        end

        expect(terminal.string.split("\n").map { it[/\A[^\r]*/] }).to eq(
          ["quaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites)",
           "quaack: [1/3] Asking the LLM (llm-rewrites, groq)",
           "quaack: [2/3] Testing each rewrite for wrong results (rewrite-correctness)",
           "quaack: [2/3] Rewrite Silver Fox: Asking the LLM for rows that could break the rewrite (counterexamples)",
           "quaack: [2/3] Asking the LLM for rows that could break the rewrite (llm-counterexamples, opus)"]
        )
      end

      it "waits on a short line in place of a sub-step's repeated ask after a note, and keeps the ask after it ends" do
        live.step("rewrite-correctness", "Testing each rewrite for wrong results") do
          sub = live.within("Rewrite Silver Fox")
          sub.step("counterexamples", "Asking the LLM for rows that could break the rewrite") do
            sub.step_note("counterexamples", "Reading the rewrite's shape for the LLM")
            live.note("Asking the LLM for rows that could break the rewrite (llm-counterexamples)")
            live.note("Asking the LLM again, for different rows (llm-counterexamples)")
          end
          live.note("Asking the LLM for rows that could break the rewrite (llm-counterexamples)")
        end

        expect(terminal.string.split("\n").map { it[/\A[^\r]*/] }).to eq(
          ["quaack: [1/3] Testing each rewrite for wrong results (rewrite-correctness)",
           "quaack: [1/3] Rewrite Silver Fox: Asking the LLM for rows that could break the rewrite (counterexamples)",
           "quaack: [1/3] Rewrite Silver Fox: Reading the rewrite's shape for the LLM (counterexamples)",
           "quaack: [1/3] Waiting for the LLM (llm-counterexamples)",
           "quaack: [1/3] Asking the LLM again, for different rows (llm-counterexamples)",
           "quaack: [1/3] Asking the LLM for rows that could break the rewrite (llm-counterexamples)"]
        )
      end

      it "keeps notes that add something: another ask, another step's ID or none, or more words" do
        live.step("llm-index-ideas", "Asking the LLM for index ideas") do
          live.note("Asking the LLM for index ideas (llm-index-ideas)")
          now[0] = 4.0
          live.note("Asking the LLM again, for replacements for the dropped ideas (llm-index-ideas)")
          live.note("Asking the LLM for index ideas, attempt 2 (llm-index-ideas)")
        end
        live.step("operator-rewrites", "Checking your own rewrites") { live.note("Asking the LLM (operator-rewrites)") }
        live.step("llm-rewrites", "Asking the LLM") { live.note("Asking the LLM (llm-counterexamples)") }
        live.step("llm-index-refine", "Asking the LLM") { live.note("Asking the LLM for more (llm-index-refine)") }
        live.step("llm-rewrites", "Asking the LLM") { live.note("Asking the LLM") }

        expect(terminal.string.split("\n")).to eq(
          ["quaack: [1/3] Asking the LLM for index ideas (llm-index-ideas)" \
           "\r\e[Kquaack: [1/3] Asking the LLM for index ideas (llm-index-ideas) 4s",
           "quaack: [1/3] Asking the LLM again, for replacements for the dropped ideas (llm-index-ideas)" \
           "\r\e[Kquaack: [1/3] Asking the LLM again, for replacements for the dropped ideas (llm-index-ideas) 4s",
           "quaack: [1/3] Asking the LLM for index ideas, attempt 2 (llm-index-ideas)" \
           "\r\e[Kquaack: [1/3] Asking the LLM for index ideas, attempt 2 (llm-index-ideas) 4s",
           "quaack: [2/3] Checking your own rewrites (operator-rewrites)",
           "quaack: [2/3] Asking the LLM (operator-rewrites)\r\e[Kquaack: [2/3] Asking the LLM (operator-rewrites) 0s",
           "quaack: [3/3] Asking the LLM (llm-rewrites)",
           "quaack: [3/3] Asking the LLM (llm-counterexamples)" \
           "\r\e[Kquaack: [3/3] Asking the LLM (llm-counterexamples) 0s",
           "quaack: [4/3] Asking the LLM (llm-index-refine)",
           "quaack: [4/3] Asking the LLM for more (llm-index-refine)" \
           "\r\e[Kquaack: [4/3] Asking the LLM for more (llm-index-refine) 0s",
           "quaack: [5/3] Asking the LLM (llm-rewrites)",
           "quaack: [5/3] Asking the LLM\r\e[Kquaack: [5/3] Asking the LLM 0s"]
        )
      end
    end

    it "never redraws a line once a note has ended it, however fast notes come" do
      # A slow terminal, so the timer gets its chance in the middle of a note.
      slow = Class.new(StringIO) do
        def tty? = true

        def print(*)
          super.tap { sleep(0.001) }
        end
      end.new
      # A clock a second later at every read, so every redraw is new.
      ticks = [0.0]
      p = described_class.new(io: slow, total: 3, clock: -> { ticks[0] += 1 }, interval: 0.0005)
      p.step("llm-rewrites", "Asking") do
        50.times { |n| p.note("Note #{n}") }
      end

      expect(slow.string.scan("\r\e[Kquaack").size).to be > 10
      slow.string.split("\n").each do |line|
        text = line[/\A[^\r]*/]
        expect(line.scan(/\r\e\[K([^\r]*) \d+(?:m\d\ds)?s(?=\r|\z)/).flatten.uniq - [text]).to eq([])
      end
    end
  end

  it "prints no clock and no still-working lines when its io isn't a terminal, and starts no thread" do
    now = [0.0]
    threads = []
    p = described_class.new(io:, total: 3, clock: -> { now.first }, interval: 0.005)
    p.step("llm-rewrites", "Asking the LLM for rewrites of the query") do
      p.note("Asking the LLM (llm-rewrites)")
      threads << Thread.list.size
      now[0] = 70.0
      sleep(0.05)
    end

    expect(threads).to eq([Thread.list.size])
    expect(io.string).to eq("quaack: [1/3] Asking the LLM for rewrites of the query (llm-rewrites)\n" \
                            "quaack: [1/3] Asking the LLM (llm-rewrites)\n" \
                            "quaack: [1/3] Done in 1m10s (llm-rewrites)\n")
  end

  it "prints every line, closing, summary, and note alike, when its io isn't a terminal" do
    times.replace([0.0, 2.0, 10.0, 10.5, 20.0, 51.0, 60.0, 63.0])
    p = progress(total: 4)
    p.step("index-rank", "Ranking the index ideas", summary: ->(_) { "Ranked the index ideas" }) { nil }
    p.step("arena-setup", "Setting up the arena") { nil }
    p.step("llm-rewrites", "Asking the LLM for rewrites of the query", summary: ->(n) { "Got #{n} rewrites" }) do
      p.note("Asking the LLM (llm-rewrites)")
      3
    end
    expect { p.step("index-build", "Building") { raise "boom" } }.to raise_error("boom")

    expect(io.string).to eq(
      "quaack: [1/4] Ranking the index ideas (index-rank)\n" \
      "quaack: [1/4] Ranked the index ideas in 2s (index-rank)\n" \
      "quaack: [2/4] Setting up the arena (arena-setup)\n" \
      "quaack: [2/4] Done in 0s (arena-setup)\n" \
      "quaack: [3/4] Asking the LLM for rewrites of the query (llm-rewrites)\n" \
      "quaack: [3/4] Asking the LLM (llm-rewrites)\n" \
      "quaack: [3/4] Got 3 rewrites in 31s (llm-rewrites)\n" \
      "quaack: [4/4] Building (index-build)\n" \
      "quaack: [4/4] Failed after 3s (index-build)\n"
    )
  end

  describe "#within" do
    it "prints sub-steps and their skips as notes under the step, without numbering them" do
      p = progress
      p.step("plan-pruning", "Searching for indexes for each rewrite") do
        sub = p.within("Rewrite 1")
        expect(sub.step("index-search", "Searching for indexes") { :ran }).to eq(:ran)
        sub.skip("index-rank", "Ranking the index ideas")
      end

      expect(io.string.lines[1..2]).to eq(["quaack: [1/3] Rewrite 1: Searching for indexes (index-search)\n",
                                           "quaack: [1/3] Rewrite 1: Already done, skipping: " \
                                           "Ranking the index ideas (index-rank)\n"])
      expect(io.string.lines.last).to start_with("quaack: [1/3] Done")
    end

    it "prints a sub-step's note after the prefix, with the sub-step's ID" do
      p = progress
      p.step("rewrite-correctness", "Testing each rewrite") do
        p.within("Rewrite 1").within("again").step_note("counterexamples", "Loading the LLM's rows")
      end

      expect(io.string.lines[1]).to eq("quaack: [1/3] Rewrite 1, again: Loading the LLM's rows (counterexamples)\n")
    end
  end

  describe "when stderr is a pipe whose reader has closed" do
    # A real pipe, as when the program reading stderr exits. Ruby
    # ignores SIGPIPE, so each write raises Errno::EPIPE. attempts records
    # the thread of each print tried on it.
    let(:pipe) { IO.pipe }
    let(:attempts) { Queue.new }
    let(:writer) do
      w = pipe.last
      tried = attempts
      w.define_singleton_method(:print) do |*args|
        tried.push(Thread.current)
        super(*args)
      end
      w
    end

    after { pipe.each { it.close unless it.closed? } }

    it "stops writing progress and runs every step to its own result" do
      pipe.first.close
      p = described_class.new(io: writer, total: 3, clock:)
      ran = []

      first = p.step("a", "A", summary: ->(_) { "Did A" }, informative: true) { ran << :a and :one }
      p.skip("b", "B")
      second = p.step("c", "C") do
        p.note("Asking the LLM (c)")
        p.within("Rewrite Silver Fox").step("d", "D") { ran << :d }
        ran << :c and :two
      end

      expect([first, second, ran]).to eq([:one, :two, %i[a d c]])
      expect(attempts.size).to eq(1)
    end

    it "keeps a failing step's own exception" do
      pipe.first.close
      p = described_class.new(io: writer, total: 3, clock:)

      expect { p.step("a", "A") { raise "boom" } }.to raise_error("boom")
      expect(p.step("b", "B") { :next }).to eq(:next)
    end

    it "keeps the step's result when the pipe closes under the live clock, and runs the next step" do
      def writer.tty? = true
      now = [0.0]
      p = described_class.new(io: writer, total: 3, clock: -> { now.first }, interval: 0.001)
      stepper = Thread.current

      tried = []
      result = p.step("a", "A") do
        pipe.first.close
        now[0] = 2.0
        tried << (attempts.pop(timeout: 10) or break) until tried.any? { it != stepper }
        :value
      end

      expect([result, tried.last]).to match([:value, satisfy { it.is_a?(Thread) && it != stepper }])
      expect(p.step("b", "B") { :next }).to eq(:next)
    end
  end

  describe "NULL" do
    it "runs steps and prints nothing" do
      expect(described_class::NULL.step("a", "b") { 7 }).to eq(7)
      expect(described_class::NULL.within("x").step("a", "b") { 8 }).to eq(8)
      expect(described_class::NULL.step_note("a", "b")).to be_nil
    end
  end
end
