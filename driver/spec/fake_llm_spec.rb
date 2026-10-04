# frozen_string_literal: true

require "quaack/driver/burndown"
require_relative "support/fake_llm"

# FakeLLM is spec support, but callers' specs lean on it, so its own rules
# get checked too.
RSpec.describe FakeLLM do
  let(:fake) { described_class.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }

  def ask(step) = client.ask(step: step, messages: [{ role: "user", content: "hi" }], max_tokens: 10)

  it "answers each step from its own script, in the order scripted" do
    fake.reply("llm-counterexamples", "other").reply("llm-rewrites", "first").reply("llm-rewrites", "second")

    expect([ask("llm-rewrites"), ask("llm-counterexamples"), ask("llm-rewrites")]).to eq(%w[first other second])
  end

  it "raises on an attempt for a step with nothing left scripted" do
    fake.reply("llm-rewrites", "only")
    ask("llm-rewrites")

    expect { ask("llm-rewrites") }.to raise_error(FakeLLM::Unscripted, /step llm-rewrites/)
    expect { ask("llm-counterexamples") }.to raise_error(FakeLLM::Unscripted, /step llm-counterexamples/)
  end

  it "records each attempt's step and request body, never its headers" do
    fake.error("llm-counterexamples", status: 529).reply("llm-counterexamples", "ok").reply("llm-rewrites", "ok")
    ask("llm-counterexamples")
    ask("llm-rewrites")

    expect(fake.asks.map(&:step)).to eq(%w[llm-counterexamples llm-counterexamples llm-rewrites])
    expect(fake.asks.map { it.body[:messages] }).to all(eq([{ role: "user", content: "hi" }]))
    expect(fake.asks.map(&:to_h).inspect).not_to include("fake-key")
  end
end
