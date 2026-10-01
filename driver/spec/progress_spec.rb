# frozen_string_literal: true

require "stringio"
require "quaack/driver/progress"

RSpec.describe Quaack::Driver::Progress do
  let(:io) { StringIO.new }
  let(:times) { [0.0] }
  # A clock that reads each queued time in turn, then keeps the last.
  let(:clock) { -> { times.size > 1 ? times.shift : times.first } }

  def progress(total: 3, interval: 30) = described_class.new(io:, total:, clock:, interval:)

  it "prints a numbered start line and a done line with the step's time" do
    times.replace([0.0, 42.4])
    result = progress.step("5a-5", "generator three (LLM)") { :value }

    expect(result).to eq(:value)
    expect(io.string).to eq("quaack: [1/3] 5a-5 generator three (LLM)\nquaack: [1/3] 5a-5 done in 42s\n")
  end

  it "numbers each step and skip in turn, and prints a skip line" do
    p = progress
    p.skip("index-search")
    p.step("5a-5", "generator three (LLM)") { nil }

    expect(io.string.lines.first).to eq("quaack: [1/3] index-search: already done, skipping\n")
    expect(io.string.lines[1]).to eq("quaack: [2/3] 5a-5 generator three (LLM)\n")
  end

  it "prints notes under the current step" do
    p = progress
    p.step("6a", "rewrite generation (LLM)") { p.note("LLM ask 6a") }

    expect(io.string.lines[1]).to eq("quaack: [1/3] LLM ask 6a\n")
  end

  it "prints minutes and hours in times" do
    times.replace([0.0, 90.0])
    p = progress
    p.step("a", "a") { nil }
    times.replace([0.0, 3725.0])
    p.step("b", "b") { nil }

    expect(io.string.lines.grep(/done/)).to eq(["quaack: [1/3] a done in 1m30s\n",
                                                "quaack: [2/3] b done in 1h02m05s\n"])
  end

  it "prints a failed line with the time, and re-raises, when the step raises" do
    times.replace([0.0, 3.0])
    expect { progress.step("6a", "rewrite generation (LLM)") { raise "boom" } }.to raise_error("boom")
    expect(io.string.lines.last).to eq("quaack: [1/3] 6a failed after 3s\n")
  end

  it "prints a still-running line every interval while a step runs, and leaves no thread behind" do
    times.replace([0.0, 30.0, 90.0, 95.0])
    before = Thread.list.size
    progress(interval: 0.01).step("5a-5", "generator three (LLM)") do
      400.times { io.string.lines.size >= 3 ? break : sleep(0.005) }
    end

    expect(io.string.lines[1..2]).to eq(["quaack: [1/3] 5a-5 still running (30s)\n",
                                         "quaack: [1/3] 5a-5 still running (1m30s)\n"])
    expect(io.string.lines.last).to eq("quaack: [1/3] 5a-5 done in 1m35s\n")
    expect(Thread.list.size).to eq(before)
  end

  it "stops its timer thread when a step fails, too" do
    before = Thread.list.size
    expect { progress(interval: 0.01).step("x", "x") { raise "boom" } }.to raise_error("boom")
    expect(Thread.list.size).to eq(before)
  end

  it "prints nothing still running for a step shorter than the interval" do
    progress(interval: 30).step("x", "x") { nil }
    expect(io.string).not_to include("still running")
  end

  describe "#within" do
    it "prints sub-steps and their skips as notes under the step, without numbering them" do
      p = progress
      p.step("step 8", "per-rewrite index search") do
        sub = p.within("rewrite_1")
        expect(sub.step("index-search", "x") { :ran }).to eq(:ran)
        sub.skip("index-rank")
      end

      expect(io.string.lines[1..2]).to eq(["quaack: [1/3] rewrite_1 index-search\n",
                                           "quaack: [1/3] rewrite_1 index-rank: already done, skipping\n"])
      expect(io.string.lines.last).to start_with("quaack: [1/3] step 8 done")
    end
  end

  describe "NULL" do
    it "runs steps and prints nothing" do
      expect(described_class::NULL.step("a", "b") { 7 }).to eq(7)
      expect(described_class::NULL.within("x").step("a", "b") { 8 }).to eq(8)
    end
  end
end
