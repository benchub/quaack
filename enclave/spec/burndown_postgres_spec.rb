# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/burndown"
require "quaack/enclave/single_candidate_test"

# The 5a-4 burndown record from a real SingleCandidateTest report, run
# against HypoPG on the test harness.
RSpec.describe Quaack::Enclave::Burndown do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "t") }
  let(:sentinel) { "sentinel_5a4_burndown" }

  around do |example|
    Dir.mktmpdir("quaack-burndown-postgres-spec") do |tmp|
      @base = File.join(tmp, "runs")
      example.run
    end
  end

  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS hypopg;
      CREATE TABLE t (a int, c int, s int);
      INSERT INTO t SELECT i, i, i % 10 FROM generate_series(1, 100000) AS i;
    SQL
    conn.exec("VACUUM ANALYZE t")
  end

  def candidate(**) = Quaack::Enclave::IndexCandidate.new(table: t, sources: [:parse], **)

  # Four candidates, planned for three literal sets: two the planner uses,
  # one it never uses, and one HypoPG refuses.
  def report
    Quaack::Enclave::SingleCandidateTest.run(
      conn, query: "SELECT * FROM t WHERE a = $1",
            literal_sets: { slow: ["5"], worst: ["7"], typical: ["70000"] },
            candidates: [candidate(key: ["a"]), candidate(key: ["c"]), candidate(key: %w[a c]),
                         candidate(key: ["a"], predicate: "s = '#{sentinel}'")]
    )
  end

  it "records what the planner used, what it never used, and what HypoPG refused, and counts the EXPLAINs" do
    tested = report
    expect(tested.results.map(&:used?)).to eq([true, false, true, false])
    expect(tested.results.map(&:refusal).map { it&.rule }).to eq([nil, nil, nil, :hypopg_refused])

    described_class.record_single_candidate_test(store, tested, search: :original)

    burndown = described_class.read(Quaack::Enclave::Store.open(store.run_id, base: @base))
    expect(burndown["stages"]).to eq(
      "5a-4" => { "original" => { "in" => 4, "added" => {}, "dropped" => { "never_used" => 1, "hypopg_refused" => 1 },
                                  "set_aside" => 0, "out" => 2, "extra" => {} } }
    )
    expect(burndown["totals"]).to eq("hypothetical_explains" => 9)
    expect(File.read(File.join(store.path, "burndown.json"))).not_to include(sentinel)
  end

  it "records the LLM's run of 5a-4 under the stage the caller names, adding to the totals" do
    tested = report
    described_class.record_single_candidate_test(store, tested, search: :original)
    described_class.record_single_candidate_test(store, tested, stage: "5a-5", search: :original)

    burndown = described_class.read(store)
    expect(burndown["stages"].keys).to eq(%w[5a-4 5a-5])
    expect(burndown.dig("stages", "5a-5", "original", "out")).to eq(2)
    expect(burndown["totals"]).to eq("hypothetical_explains" => 18)
  end
end
