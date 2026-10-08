# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/provenance"

RSpec.describe Quaack::Driver::Provenance do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      example.run
    end
  end

  let(:run_id) { "20261008T120000Z-0123abcd" }
  let(:path) { File.join(@home, ".quaack", "runs", "#{run_id}.llm.json") }
  let(:provenance) { described_class.open(@home, run_id) }

  def saved = JSON.parse(File.read(path))

  def outcome(index, outcome, rule = nil)
    { "type" => "index_outcome", "index" => index, "outcome" => outcome,
      "rule" => rule }
  end

  it "writes ~/.quaack/runs/<run ID>.llm.json, mode 0600, in a 0700 runs directory" do
    old = File.umask(0o000)
    begin
      provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
      provenance.save
    ensure
      File.umask(old)
    end

    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    expect(saved["providers"]).to eq([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
  end

  it "writes the record whole to a temporary file and renames it into place, leaving nothing else" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
    provenance.save
    before = File.stat(path).ino
    provenance.operator_inference!("groq")
    provenance.save

    expect(File.stat(path).ino).not_to eq(before)
    expect(Dir.children(File.dirname(path))).to eq(["#{run_id}.llm.json"])
    expect(saved["operator_inference"]).to eq("groq")
  end

  it "records each rewrite's author by store name, and how many each entry proposed" do
    outcomes = [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rewrite" => "rewrite_3" },
                { "type" => "rewrite_outcome", "index" => 2, "outcome" => "rejected", "rule" => "too_many",
                  "rewrite" => nil },
                { "type" => "rewrite_outcome", "index" => 3, "outcome" => "accepted", "rewrite" => "rewrite_4" }]
    provenance.rewrites!("groq", outcomes, proposed: 3)
    provenance.save

    expect(saved["rewrites"]).to eq("rewrite_3" => "groq", "rewrite_4" => "groq")
    expect(saved["rewrites_proposed"]).to eq("groq" => 3)
  end

  it "records each entry that ran a rewrite's counterexample rounds, in order, with the rule before a fresh start" do
    provenance.counterexamples!("rewrite_2", [{ "entry" => "groq", "rounds" => 1 },
                                              { "entry" => "opus", "rounds" => 2, "after" => "llm_rate_limited" }])
    provenance.save

    expect(saved["counterexamples"]).to eq(
      "rewrite_2" => [{ "entry" => "groq", "rounds" => 1 },
                      { "entry" => "opus", "rounds" => 2, "after" => "llm_rate_limited" }]
    )
  end

  it "counts each index round's statements and outcomes by entry, and each skipped replacement round" do
    provenance.index_round!("original", "first", "groq", 3,
                            [outcome(1, "accepted"), outcome(2, "dropped", "duplicate"), outcome(3, "set_aside")])
    provenance.index_round!("rewrite_2", "refinement", "opus", 1, [outcome(1, "dropped", "covered_by_existing")])
    provenance.skipped!("original", "groq", "llm_unavailable")
    provenance.save

    expect(saved["index_ideas"]).to eq(
      "original" => { "first" => { "groq" => { "written" => 3,
                                               "outcomes" => { "accepted" => 1, "dropped" => 1, "set_aside" => 1 },
                                               "rules" => { "duplicate" => 1 } } },
                      "skipped" => [{ "entry" => "groq", "rule" => "llm_unavailable" }] },
      "rewrite_2" => { "refinement" => { "opus" => { "written" => 1, "outcomes" => { "dropped" => 1 },
                                                     "rules" => { "covered_by_existing" => 1 } } } }
    )
  end

  it "records which providers the run marked down or dropped, by rule" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" },
                           { "name" => "opus", "provider" => "anthropic", "model" => "claude-opus-5-5" }])
    provenance.down!("groq" => "llm_auth")
    provenance.save

    expect(saved["providers"].map { it["down"] }).to eq(["llm_auth", nil])
  end

  it "keeps the record across a resume, adding new entries and keeping the old ones" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
    provenance.rewrites!("groq", [{ "outcome" => "accepted", "rewrite" => "rewrite_1" }], proposed: 1)
    provenance.save

    resumed = described_class.open(@home, run_id)
    resumed.providers!([{ "name" => "opus", "provider" => "anthropic", "model" => "claude-opus-5-5" }])
    resumed.save

    expect(saved["providers"].map { it["name"] }).to eq(%w[groq opus])
    expect(saved["rewrites"]).to eq("rewrite_1" => "groq")
    expect(resumed.author("rewrite_1")).to eq("name" => "groq", "provider" => "openai_compatible",
                                              "model" => "llama")
  end

  it "reads as empty when there's no record, and says nothing of what it lacks" do
    expect(provenance.record).to eq({})
    expect(provenance.author("rewrite_1")).to be_nil
  end

  it "keeps only well-formed parts of a record it reads, so nothing else reaches the report" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       "providers" => [{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" },
                                       { "name" => "Bad Name", "provider" => "anthropic", "model" => "x" },
                                       "not an object"],
                       "rewrites" => { "rewrite_1" => "groq", "SELECT 1" => "groq", "rewrite_2" => 5 },
                       "rewrites_proposed" => { "groq" => -1 },
                       "operator_inference" => ["groq"],
                       "extra" => "SELECT secret"
                     ))

    expect(provenance.record).to eq(
      "providers" => [{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }],
      "rewrites" => { "rewrite_1" => "groq" }
    )
  end

  it "reads a record that isn't JSON, or isn't an object, as empty" do
    FileUtils.mkdir_p(File.dirname(path))
    ["{", "[1]", "null"].each do |text|
      File.write(path, text)
      expect(described_class.open(@home, run_id).record).to eq({})
    end
  end

  it "refuses a run ID that isn't one, since it becomes a file name" do
    expect { described_class.open(@home, "../x") }.to raise_error(ArgumentError)
  end
end
