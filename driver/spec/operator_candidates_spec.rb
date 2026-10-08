# frozen_string_literal: true

require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/operator_candidates"
require_relative "support/fake_llm"
require_relative "support/routers"

RSpec.describe Quaack::Driver::OperatorCandidates do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) do
    { "query" => "SELECT o.id FROM public.orders o WHERE o.id IN (SELECT order_id FROM public.items WHERE sku = $1)",
      "placeholders" => {}, "plan" => [], "schema" => {}, "stats" => {} }
  end
  let(:first) { "SELECT DISTINCT o.id FROM public.orders o JOIN public.items i ON i.order_id = o.id WHERE i.sku = $1" }
  let(:second) { "SELECT o.id FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.items i WHERE i.sku = ';')" }
  let(:inferred) do
    [{ "transformation" => "IN to join", "assumptions" => [] },
     { "transformation" => "IN to EXISTS",
       "assumptions" => [{ "kind" => "not_null", "table" => "public.items", "column" => "order_id" }] }]
  end
  let(:sent) { [] }
  let(:rewrite_check) { ->(rewrites) { (sent << rewrites) && [{ "type" => "rewrite_outcome", "index" => 1 }] } }

  describe ".statements" do
    it "splits the file into one rewrite per ;-terminated statement, keeping a ; inside a string" do
      expect(described_class.statements("#{first};\n\n  #{second};\n")).to eq([first, second])
    end

    it "refuses text that doesn't parse, or trails a statement with no ;" do
      expect { described_class.statements("SELEC 1;") }.to raise_error(described_class::Error, /parse/)
      expect { described_class.statements("#{first}; #{second}") }.to raise_error(described_class::Error, /;/)
    end
  end

  it "reads a file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rewrites.sql")
      File.write(path, "#{first};\n")
      expect(described_class.from_file(path)).to eq([first])
    end
  end

  it "asks the LLM to infer each rewrite's transformation and assumptions, then checks them as inferred" do
    fake.reply("operator-rewrites", { "rewrites" => inferred })

    result = described_class.new(client:, rewrite_check:).run(payload, [first, second])

    ask = fake.asks.first
    expect(ask.step).to eq("operator-rewrites")
    body = JSON.parse(ask.body[:messages].first[:content][/```json\n(.*)\n```/m, 1])
    expect(body).to eq("payload" => payload, "rewrites" => [first, second])
    expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
    expect(sent).to eq([[{ "sql" => first }.merge(inferred[0]), { "sql" => second }.merge(inferred[1])]])
    expect(result.outcomes).to eq([{ "type" => "rewrite_outcome", "index" => 1 }])
    expect(result.provider).to eq("anthropic")
  end

  it "refuses an LLM answer that doesn't cover each rewrite once, without calling the enclave" do
    fake.reply("operator-rewrites", { "rewrites" => inferred.first(1) })

    expect { described_class.new(client:, rewrite_check:).run(payload, [first, second]) }
      .to raise_error(described_class::Error, /2/)
    expect(sent).to eq([])
  end

  it "builds rewrite_check over the transport with inferred: true" do
    calls = []
    transport = Object.new
    transport.define_singleton_method(:call) do |name, **kw|
      calls << [name, kw]
      Struct.new(:messages).new([{ "type" => "done" }])
    end

    described_class.rewrite_check(transport, run_id: "R").call([{ "sql" => first }])

    expect(calls).to eq([["rewrite-check", { args: { run: "R" },
                                             input: { "rewrites" => [{ "sql" => first }], "inferred" => true } }]])
  end
end
