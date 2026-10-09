# frozen_string_literal: true

require "quaack/enclave/store"
require "quaack/enclave/steps/baseline"

# `quaacks minimax --run <run ID>` (DESIGN.md's blocks-metric, minimax) the way the jump server
# runs it. It reads baseline, index_baseline, candidate_runs, and index_build,
# needs no connection, and prints only DONE.
RSpec.describe "quaacks minimax" do
  let(:quaacks) { LeakCheck::Quaacks.new }

  def m(blocks) = { "timed_out" => false, "stable" => true, "total_blocks" => blocks }
  def sets(slow, other = 100) = { "slow" => m(slow), "worst_case" => m(other), "typical" => m(other) }

  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |s|
      s.write("baseline", "sets" => sets(1000), "timed_out" => [], "timeout_ms" => 5000)
      s.write("index_build",
              "indexes" => { "i_a" => { "ddl" => "x", "size" => 800 }, "i_b" => { "ddl" => "y", "size" => 100 } },
              "combinations" => { "original:top:1" => ["i_a"], "original:top:2" => ["i_b"],
                                  "original:top:3" => ["i_b"], "rewrite_1:top:1" => %w[i_a i_b] })
      s.write("index_baseline", "combinations" => { "original:top:1" => sets(500), "original:top:2" => sets(510),
                                                    "original:top:3" => { "slow" => { "timed_out" => true } } },
                                "timed_out" => ["original:top:3"])
      s.write("candidate_runs", "candidates" => { "rewrite_1" => { "none" => sets(300),
                                                                   "rewrite_1:top:1" => sets(100, 200) } },
                                "timed_out" => [], "timed_out_count" => 0)
    end
  end

  after { quaacks.remove }

  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  it "stores ranked survivors with footprints and per-literal verdicts, printing only DONE" do
    outcome = quaacks.run("minimax", "--run", store.run_id, env: ENV.keys.grep(/\APG/).to_h { [it, nil] })

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([counts_then_done(compared: 4, survivors: 2), "", 0])
    result = stored.read("minimax")
    expect(result["survivors"].map { it.slice("label", "footprint") }).to eq(
      [{ "label" => "rewrite_1:none", "footprint" => 0 }, { "label" => "original:top:2", "footprint" => 100 }]
    )
    expect(result["discarded_ties"]).to eq(["original:top:1"])
    expect(result["verdicts"]["rewrite_1:top:1"]).to eq("slow" => "better", "worst_case" => "worse",
                                                        "typical" => "worse")
    expect(result["verdicts"]).not_to have_key("original:top:3")
    expect(result["infinite_sets"]).to eq([])
  end
end

RSpec.describe Quaack::Enclave::Steps::Baseline do
  def baseline_store(quaacks)
    store = Quaack::Enclave::Store.create(base: quaacks.store_base)
    store.write("anchored_query", "SELECT 1")
    connection = instance_double(PG::Connection, close: nil)
    allow(Quaack::Enclave::RunServer).to receive(:connect).with(store, :racetrack).and_return(connection)
    store
  end

  it "gives the original's measurement the config's cap per run, one hour without one" do
    quaacks = LeakCheck::Quaacks.new
    store = baseline_store(quaacks)
    seen = []
    allow(Quaack::Enclave::Measurement).to receive(:measure) do |**kw|
      seen << kw[:timeout_ms]
      {}
    end

    described_class.call(store:, config: Quaack::Enclave::Config.new({}))
    described_class.call(store:, config: Quaack::Enclave::Config.new({ "baseline_cap_seconds" => 90 }))

    expect(seen).to eq([3_600_000, 90_000])
  ensure
    quaacks&.remove
  end

  it "refuses as baseline_original_exceeded_cap when the original times out, and stores no baseline" do
    quaacks = LeakCheck::Quaacks.new
    store = baseline_store(quaacks)
    allow(Quaack::Enclave::Measurement).to receive(:measure)
      .and_return({ "slow" => { "timed_out" => true, "ran" => 1 } })

    expect { described_class.call(store:, config: Quaack::Enclave::Config.new({})) }
      .to raise_error(described_class::Error) { |e| expect(e.rule).to eq("baseline_original_exceeded_cap") }
    expect { store.read("baseline") }.to raise_error(Quaack::Enclave::Store::MissingEntry)
  ensure
    quaacks&.remove
  end

  it "clamps the candidates' timeout when every set timed out" do
    entry = described_class.entry({ "slow" => { "timed_out" => true } })
    expect(entry).to include("timed_out" => ["slow"], "timeout_ms" => Quaack::Enclave::RunDiscipline::MAX_MS)
  end
end
