# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/counterexamples"
require_relative "support/fake_llm"

# 10a, the driver's half: ask the LLM for shape-level inserts that should
# make a candidate and the original disagree.
RSpec.describe Quaack::Driver::Counterexamples do
  let(:fake) { FakeLLM.new }
  let(:client) { fake.client(burndown: Quaack::Driver::Burndown.new) }
  let(:payload) do
    { "original" => "SELECT o.id FROM public.orders o WHERE o.status = $1",
      "candidate" => { "sql" => "SELECT o.id FROM public.orders o WHERE lower(o.status) = $1",
                       "transformation" => "lowercases status", "assumptions" => ["status is lowercase"] },
      "placeholders" => { "$1" => "text" }, "schema" => "CREATE TABLE public.orders (id integer, status text)",
      "constraints" => ["orders_pkey PRIMARY KEY (id)"], "untested_atoms" => ["o.status = $1"] }
  end
  let(:insert) { "INSERT INTO public.orders (id, status) VALUES (1, upper($1))" }

  def user_texts(ask) = ask.body[:messages].select { it[:role] == :user }.map { it[:content] }

  it "sends the payload and returns the LLM's inserts" do
    fake.reply("10a", { "inserts" => [insert] })
    expect(described_class.new(client:).ask(payload)).to eq([insert])
    ask = fake.asks.first
    expect(JSON.parse(user_texts(ask).first[/```json\n(.*)\n```/m, 1])).to eq(payload)
    expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
  end

  it "tells the LLM to use $n for the query's literals, to aim at untested atoms, and to satisfy every constraint" do
    fake.reply("10a", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("$1", "untested_atoms", "every constraint", "schema-qualif")
  end
end
