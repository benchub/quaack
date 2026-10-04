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
    result = progress.step("5a-5", "Asking the LLM for index ideas") { :value }

    expect(result).to eq(:value)
    expect(io.string).to eq("quaack: [1/3] Asking the LLM for index ideas (5a-5)\nquaack: [1/3] Done in 42s (5a-5)\n")
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
      progress.step("5a-7", "Ranking", summary: ->(_) {}) { :ranked }

      expect(io.string.lines.last).to eq("quaack: [1/3] Done in 2s (5a-7)\n")
    end

    it "closes a failed step with its failed line, without a summary" do
      times.replace([0.0, 3.0])
      expect { progress.step("6a", "Asking", summary:) { raise "boom" } }.to raise_error("boom")

      expect(io.string.lines.last).to eq("quaack: [1/3] Failed after 3s (6a)\n")
    end

    it "is taken, and ignored, by sub-steps and NULL, which print no closing line" do
      p = progress
      p.step("step 8", "Searching") do
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
    p.step("5a-5", "Asking the LLM for index ideas") { nil }

    expect(io.string.lines.first).to eq("quaack: [1/3] Already done, skipping: Searching for indexes (index-search)\n")
    expect(io.string.lines[1]).to eq("quaack: [2/3] Asking the LLM for index ideas (5a-5)\n")
  end

  it "prints notes under the current step" do
    p = progress
    p.step("6a", "Asking the LLM for rewrites") { p.note("Asking the LLM (6a)") }

    expect(io.string.lines[1]).to eq("quaack: [1/3] Asking the LLM (6a)\n")
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
    expect { progress.step("6a", "Asking the LLM for rewrites") { raise "boom" } }.to raise_error("boom")
    expect(io.string.lines.last).to eq("quaack: [1/3] Failed after 3s (6a)\n")
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
      live.step("6a", "Asking the LLM for rewrites of the query") do
        live.note("Asking the LLM (6a)")
        now[0] = 1.2
        wait_for(terminal, "(6a) 1s\e[K")
        sleep(0.05) # many redraws' time, at the same reading
        now[0] = 61.0
        wait_for(terminal, "(6a) 1m01s\e[K")
        now[0] = 65.0
        live.note("Asking the LLM, attempt 2 (6a)")
        now[0] = 70.0
      end

      expect(terminal.string).to eq(
        "quaack: [1/3] Asking the LLM for rewrites of the query (6a)\n" \
        "quaack: [1/3] Asking the LLM (6a)" \
        "\rquaack: [1/3] Asking the LLM (6a) 1s\e[K" \
        "\rquaack: [1/3] Asking the LLM (6a) 1m01s\e[K" \
        "\rquaack: [1/3] Asking the LLM (6a) 1m05s\e[K\n" \
        "quaack: [1/3] Asking the LLM, attempt 2 (6a)" \
        "\rquaack: [1/3] Asking the LLM, attempt 2 (6a) 1m10s\e[K\n" \
        "quaack: [1/3] Done in 1m10s (6a)\n"
      )
      expect(Thread.list.size).to eq(before)
    end

    it "puts no clock on a line that ends within the step's first second, and ends whole lines between steps" do
      live.skip("index-search", "Searching for indexes")
      live.step("5a-5", "Asking the LLM for index ideas") { now[0] = 0.4 }
      live.note("Between steps")

      expect(terminal.string).to eq(
        "quaack: [1/3] Already done, skipping: Searching for indexes (index-search)\n" \
        "quaack: [2/3] Asking the LLM for index ideas (5a-5)\n" \
        "quaack: [2/3] Done in 0s (5a-5)\n" \
        "quaack: [2/3] Between steps\n"
      )
    end

    it "stops redrawing when a step fails, so nothing lands after its failed line" do
      before = Thread.list.size
      expect do
        live.step("6a", "Asking") do
          now[0] = 2.0
          wait_for(terminal, "(6a) 2s\e[K")
          now[0] = 3.0
          raise "boom"
        end
      end.to raise_error("boom")
      ended = terminal.string.dup
      now[0] = 9.0
      sleep(0.05)

      expect(terminal.string).to eq(ended)
      expect(ended).to end_with("Asking (6a) 3s\e[K\nquaack: [1/3] Failed after 3s (6a)\n")
      expect(Thread.list.size).to eq(before)
    end

    it "stops redrawing when a step is interrupted, too" do
      before = Thread.list.size
      expect { live.step("6a", "Asking") { raise Interrupt } }.to raise_error(Interrupt)
      ended = terminal.string.dup
      now[0] = 9.0
      sleep(0.05)

      expect(terminal.string).to eq("quaack: [1/3] Asking (6a)\nquaack: [1/3] Failed after 0s (6a)\n")
      expect(terminal.string).to eq(ended)
      expect(Thread.list.size).to eq(before)
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
        fitted.step("5a-5", "Asking the LLM for index ideas the mechanical search missed") do
          now[0] = 70.0
          wait_for(narrow, " 1m10s\e[K")
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM for index…" \
          "\rquaack: [1/3] Asking the LLM for… 1m10s\e[K" \
          "\rquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (5a-5) 1m10s\e[K\n" \
          "quaack: [1/3] Done in 1m10s (5a-5)\n"
        )
      end

      it "cuts a line only once its clock won't fit, and reads the width at each redraw" do
        narrow.columns = 36
        fitted.step("6a", "Asking the LLM") do
          now[0] = 1.2
          wait_for(narrow, " 1s\e[K")
          narrow.columns = 80
          now[0] = 61.0
          wait_for(narrow, " 1m01s\e[K")
        end

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM (6a)" \
          "\rquaack: [1/3] Asking the LLM (6… 1s\e[K" \
          "\rquaack: [1/3] Asking the LLM (6a) 1m01s\e[K\n" \
          "quaack: [1/3] Done in 1m01s (6a)\n"
        )
      end

      it "prints a cut line whole when it ends, even once the terminal is wide enough for it" do
        narrow.columns = 40
        fitted.step("5a-5", "Asking the LLM for index ideas the mechanical search missed") { narrow.columns = 200 }

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM for index…" \
          "\rquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (5a-5)\e[K\n" \
          "quaack: [1/3] Done in 0s (5a-5)\n"
        )
      end

      it "prints a line whole when it ends, if its final reading won't fit beside it" do
        narrow.columns = 36
        slow = described_class.new(io: narrow, total: 3, clock: -> { now.first }, interval: 60)
        slow.step("6a", "Asking the LLM") { now[0] = 1.2 }

        expect(narrow.string).to eq(
          "quaack: [1/3] Asking the LLM (6a)" \
          "\rquaack: [1/3] Asking the LLM (6a) 1s\e[K\n" \
          "quaack: [1/3] Done in 1s (6a)\n"
        )
      end

      it "keeps within a terminal too narrow for the clock" do
        narrow.columns = 5
        fitted.step("6a", "Asking") do
          now[0] = 2.0
          wait_for(narrow, "\r")
        end

        expect(narrow.string).to eq("qua…\rqua…\e[K\rquaack: [1/3] Asking (6a) 2s\e[K\nquaack: [1/3] Done in 2s (6a)\n")
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
                         .step("5a-5", "Asking the LLM for index ideas the mechanical search missed") { now[0] = 2.0 }

          expect(out.string).to eq(
            "quaack: [1/3] Asking the LLM for index ideas the mechanical search missed (5a-5)" \
            "\rquaack: [1/3] Asking the LLM for index ideas the mechanical search missed (5a-5) 2s\e[K\n" \
            "quaack: [1/3] Done in 2s (5a-5)\n"
          )
        end
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
      p.step("6a", "Asking") do
        50.times { |n| p.note("Note #{n}") }
      end

      expect(slow.string.scan("\rquaack").size).to be > 10
      slow.string.split("\n").each do |line|
        text = line[/\A[^\r]*/]
        expect(line.scan(/\r([^\r]*?) \d+(?:m\d\ds)?s\e\[K/).flatten.uniq - [text]).to eq([])
      end
    end
  end

  it "prints no clock and no still-working lines when its io isn't a terminal, and starts no thread" do
    now = [0.0]
    threads = []
    p = described_class.new(io:, total: 3, clock: -> { now.first }, interval: 0.005)
    p.step("6a", "Asking the LLM for rewrites of the query") do
      p.note("Asking the LLM (6a)")
      threads << Thread.list.size
      now[0] = 70.0
      sleep(0.05)
    end

    expect(threads).to eq([Thread.list.size])
    expect(io.string).to eq("quaack: [1/3] Asking the LLM for rewrites of the query (6a)\n" \
                            "quaack: [1/3] Asking the LLM (6a)\n" \
                            "quaack: [1/3] Done in 1m10s (6a)\n")
  end

  describe "#within" do
    it "prints sub-steps and their skips as notes under the step, without numbering them" do
      p = progress
      p.step("step 8", "Searching for indexes for each rewrite") do
        sub = p.within("Rewrite 1")
        expect(sub.step("index-search", "Searching for indexes") { :ran }).to eq(:ran)
        sub.skip("index-rank", "Ranking the index ideas")
      end

      expect(io.string.lines[1..2]).to eq(["quaack: [1/3] Rewrite 1: Searching for indexes (index-search)\n",
                                           "quaack: [1/3] Rewrite 1: Already done, skipping: " \
                                           "Ranking the index ideas (index-rank)\n"])
      expect(io.string.lines.last).to start_with("quaack: [1/3] Done")
    end
  end

  describe "NULL" do
    it "runs steps and prints nothing" do
      expect(described_class::NULL.step("a", "b") { 7 }).to eq(7)
      expect(described_class::NULL.within("x").step("a", "b") { 8 }).to eq(8)
    end
  end
end
