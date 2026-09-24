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
    fake.reply("10a", "other").reply("6a", "first").reply("6a", "second")

    expect([ask("6a"), ask("10a"), ask("6a")]).to eq(%w[first other second])
  end

  it "raises on an attempt for a step with nothing left scripted" do
    fake.reply("6a", "only")
    ask("6a")

    expect { ask("6a") }.to raise_error(FakeLLM::Unscripted, /step 6a/)
    expect { ask("10a") }.to raise_error(FakeLLM::Unscripted, /step 10a/)
  end

  it "records each attempt's step and request body, never its headers" do
    fake.error("10a", status: 529).reply("10a", "ok").reply("6a", "ok")
    ask("10a")
    ask("6a")

    expect(fake.asks.map(&:step)).to eq(%w[10a 10a 6a])
    expect(fake.asks.map { it.body[:messages] }).to all(eq([{ role: "user", content: "hi" }]))
    expect(fake.asks.map(&:to_h).inspect).not_to include("fake-key")
  end
end
