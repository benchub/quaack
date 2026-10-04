# frozen_string_literal: true

require "quaack/driver/burndown"

RSpec.describe Quaack::Driver::Burndown do
  let(:burndown) { described_class.new }

  it "is loaded by quaack/driver" do
    code = 'require "quaack/driver"; b = Quaack::Driver::Burndown.new; b.llm_call("6a"); print b.llm_calls'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq({ "6a" => 1 }.to_s)
  end

  it "starts with no LLM calls" do
    expect(burndown.llm_calls).to eq({})
  end

  it "counts LLM calls by step, in the order each step first called" do
    %w[5a-5 5a-5 6a 5a-5 rewrite-llm-index-ideas].each { burndown.llm_call(it) }

    expect(burndown.llm_calls).to eq("5a-5" => 3, "6a" => 1, "rewrite-llm-index-ideas" => 1)
    expect(burndown.llm_calls.keys).to eq(%w[5a-5 6a rewrite-llm-index-ideas])
  end

  it "takes every step the protocol lists as one that calls an LLM" do
    Quaack::Protocol::Burndown::LLM_STEPS.each { burndown.llm_call(it) }

    expect(burndown.llm_calls).to eq(Quaack::Protocol::Burndown::LLM_STEPS.to_h { [it, 1] })
  end

  it "refuses a step that doesn't call an LLM, counting nothing" do
    ["5a-3", "step8", "6A", :"6a", nil].each do |step|
      expect { burndown.llm_call(step) }.to raise_error(ArgumentError, /step that calls an LLM/)
    end
    expect(burndown.llm_calls).to eq({})
  end

  it "counts a step given as a String subclass under the protocol's own String" do
    burndown.llm_call(Class.new(String).new("6a"))

    expect(burndown.llm_calls.keys.map(&:class)).to eq([String])
    expect(burndown.llm_calls.keys.first).to equal(Quaack::Protocol::Burndown::LLM_STEPS[2])
  end

  it "hands out a frozen copy, so the counts change only through llm_call" do
    burndown.llm_call("6a")
    calls = burndown.llm_calls

    expect(calls).to be_frozen
    burndown.llm_call("6a")
    expect(calls).to eq("6a" => 1)
    expect(burndown.llm_calls).to eq("6a" => 2)
  end
end
