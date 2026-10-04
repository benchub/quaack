# frozen_string_literal: true

require "quaack/driver/burndown"

RSpec.describe Quaack::Driver::Burndown do
  let(:burndown) { described_class.new }

  it "is loaded by quaack/driver" do
    code = 'require "quaack/driver"; b = Quaack::Driver::Burndown.new; b.llm_call("llm-rewrites"); print b.llm_calls'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq({ "llm-rewrites" => 1 }.to_s)
  end

  it "starts with no LLM calls" do
    expect(burndown.llm_calls).to eq({})
  end

  it "counts LLM calls by step, in the order each step first called" do
    steps = %w[llm-index-ideas llm-index-ideas llm-rewrites llm-index-ideas rewrite-llm-index-ideas]
    steps.each { burndown.llm_call(it) }

    expect(burndown.llm_calls).to eq("llm-index-ideas" => 3, "llm-rewrites" => 1, "rewrite-llm-index-ideas" => 1)
    expect(burndown.llm_calls.keys).to eq(%w[llm-index-ideas llm-rewrites rewrite-llm-index-ideas])
  end

  it "takes every step the protocol lists as one that calls an LLM" do
    Quaack::Protocol::Burndown::LLM_STEPS.each { burndown.llm_call(it) }

    expect(burndown.llm_calls).to eq(Quaack::Protocol::Burndown::LLM_STEPS.to_h { [it, 1] })
  end

  it "refuses a step that doesn't call an LLM, counting nothing" do
    ["index-dedupe", "plan-pruning", "6A", :"llm-rewrites", nil].each do |step|
      expect { burndown.llm_call(step) }.to raise_error(ArgumentError, /step that calls an LLM/)
    end
    expect(burndown.llm_calls).to eq({})
  end

  it "counts a step given as a String subclass under the protocol's own String" do
    burndown.llm_call(Class.new(String).new("llm-rewrites"))

    expect(burndown.llm_calls.keys.map(&:class)).to eq([String])
    expect(burndown.llm_calls.keys.first).to equal(Quaack::Protocol::Burndown::LLM_STEPS[2])
  end

  it "hands out a frozen copy, so the counts change only through llm_call" do
    burndown.llm_call("llm-rewrites")
    calls = burndown.llm_calls

    expect(calls).to be_frozen
    burndown.llm_call("llm-rewrites")
    expect(calls).to eq("llm-rewrites" => 1)
    expect(burndown.llm_calls).to eq("llm-rewrites" => 2)
  end
end
