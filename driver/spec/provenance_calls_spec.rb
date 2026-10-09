# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/provenance"

RSpec.describe Quaack::Driver::Provenance, "LLM calls across processes" do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      example.run
    end
  end

  let(:run_id) { "20261008T120000Z-0123abcd" }
  let(:entries) { [{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }] }
  # rubocop:disable-next Lint/StructNewOverride
  let(:client_class) { Struct.new(:entries, :failed_branches, :down, :burndown) }

  def client(calls)
    burndown = Quaack::Driver::Burndown.new
    calls.each { |step| burndown.llm_call(step, "groq") }
    client_class.new(entries, [], {}, burndown)
  end

  def process(calls)
    provenance = described_class.open(@home, run_id)
    client = client(calls)
    described_class.recorder(provenance, client).call
    [provenance, client]
  end

  it "counts the calls an earlier process made, once each, in what the report reads" do
    process(%w[llm-rewrites llm-rewrites])
    provenance, client = process(%w[llm-rewrites llm-index-ideas])

    expect(described_class.llm_calls(provenance, client)).to eq("llm-rewrites" => 3, "llm-index-ideas" => 1)
    expect(described_class.for_report(provenance, client)["calls"])
      .to eq("groq" => { "llm-rewrites" => 3, "llm-index-ideas" => 1 })
  end

  it "keeps a third process's count right after two saves in the second" do
    process(%w[llm-rewrites])
    provenance = described_class.open(@home, run_id)
    client = client(%w[llm-rewrites])
    recorder = described_class.recorder(provenance, client)
    recorder.call
    client.burndown.llm_call("llm-index-ideas", "groq")
    recorder.call
    provenance, client = process([])

    expect(described_class.llm_calls(provenance, client)).to eq("llm-rewrites" => 2, "llm-index-ideas" => 1)
  end

  it "drops a stored count that isn't an LLM step's count" do
    path = described_class.path(@home, run_id)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("llm_calls" => { "steps" => { "llm-rewrites" => 2, "SENTINEL" => 9 },
                                                    "providers" => { "groq" => { "llm-rewrites" => -1 } } }))
    provenance = described_class.open(@home, run_id)

    expect(described_class.llm_calls(provenance, client([]))).to eq("llm-rewrites" => 2)
    expect(described_class.for_report(provenance, client([]))["calls"]).to eq("groq" => {})
  end

  it "adds an earlier process's wait and tokens to this one's, in what the report reads" do
    provenance, client = process([])
    client.burndown.llm_wait("groq", 1.5, { "input" => 10, "output" => 2 }, used: true)
    provenance.router!(client).save
    provenance, client = process([])
    client.burndown.llm_wait("groq", 0.5, nil, used: false)

    expect(described_class.for_report(provenance, client)["usage"])
      .to eq("groq" => { "seconds" => 2.0, "used" => 1, "reported" => 1, "input" => 10, "output" => 2 })
  end

  it "drops stored usage that isn't a provider's counts" do
    path = described_class.path(@home, run_id)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("llm_usage" => {
                                     "groq" => { "seconds" => 1.5, "used" => 1, "reported" => 1, "input" => 4,
                                                 "SENTINEL" => 9, "output" => -1 },
                                     "bad name!" => { "seconds" => 1 }, "x" => "SENTINEL"
                                   }))
    provenance = described_class.open(@home, run_id)

    expect(described_class.for_report(provenance, client([]))["usage"])
      .to eq("groq" => { "seconds" => 1.5, "used" => 1, "reported" => 1, "input" => 4 })
  end
end
