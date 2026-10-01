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

  it "prints a still-working line every interval while a step runs, and leaves no thread behind" do
    times.replace([0.0, 30.0, 90.0, 95.0])
    before = Thread.list.size
    progress(interval: 0.01).step("5a-5", "Asking the LLM for index ideas") do
      400.times { io.string.lines.size >= 3 ? break : sleep(0.005) }
    end

    expect(io.string.lines[1..2]).to eq(["quaack: [1/3] Still working, 30s so far (5a-5)\n",
                                         "quaack: [1/3] Still working, 1m30s so far (5a-5)\n"])
    expect(io.string.lines.last).to eq("quaack: [1/3] Done in 1m35s (5a-5)\n")
    expect(Thread.list.size).to eq(before)
  end

  it "stops its timer thread when a step fails, too" do
    before = Thread.list.size
    expect { progress(interval: 0.01).step("x", "x") { raise "boom" } }.to raise_error("boom")
    expect(Thread.list.size).to eq(before)
  end

  it "prints nothing still working for a step shorter than the interval" do
    progress(interval: 30).step("x", "x") { nil }
    expect(io.string).not_to include("Still working")
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
