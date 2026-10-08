# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/burndown"
require "quaack/enclave/dedupe"
require "quaack/enclave/single_candidate_test"

# The index-test burndown record from a real SingleCandidateTest report, run
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

  # A Dedupe whose proposals are exactly what the report tested.
  def proposed(report)
    candidates = report.results.map(&:candidate)
    Quaack::Enclave::Dedupe.restore(statistics: Quaack::Enclave::Statistics.new(tables: []), low_cardinality: [],
                                    proposals: candidates, set_aside: [], drops: [], considered: candidates.size)
  end

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

    described_class.record_single_candidate_test(store, tested, search: :original, dedupe: proposed(tested))

    burndown = described_class.read(Quaack::Enclave::Store.open(store.run_id, base: @base))
    expect(burndown["stages"]).to eq(
      "index-test" => { "original" => { "in" => 4, "added" => {},
                                        "dropped" => { "never_used" => 1, "hypopg_refused" => 1 },
                                        "set_aside" => 0, "out" => 2, "extra" => {} } }
    )
    expect(burndown["totals"]).to eq("hypothetical_explains" => 9)
    expect(File.read(File.join(store.path, "burndown.json"))).not_to include(sentinel)
  end

  it "leaves out a reason no candidate was dropped for" do
    tested = Quaack::Enclave::SingleCandidateTest.run(conn, query: "SELECT * FROM t WHERE a = $1",
                                                            literal_sets: { slow: ["5"] },
                                                            candidates: [candidate(key: ["a"]), candidate(key: ["c"])])
    described_class.record_single_candidate_test(store, tested, search: :original, dedupe: proposed(tested))

    expect(described_class.read(store).dig("stages", "index-test", "original", "dropped")).to eq("never_used" => 1)
  end

  it "counts an unused candidate set aside for index-build as set aside, not dropped (20260927-11)" do
    unused = candidate(key: ["c"])
    tested = Quaack::Enclave::SingleCandidateTest.run(conn, query: "SELECT * FROM t WHERE a = $1",
                                                            literal_sets: { slow: ["5"] },
                                                            candidates: [candidate(key: ["a"]), unused])
    described_class.record_single_candidate_test(store, tested, search: :original, dedupe: proposed(tested),
                                                                set_aside: [unused])

    expect(described_class.read(store).dig("stages", "index-test", "original"))
      .to include("in" => 2, "dropped" => {}, "set_aside" => 1, "out" => 1)
  end

  it "records only index-test, so it takes no stage" do
    expect do
      described_class.record_single_candidate_test(store, report, search: :original, dedupe: nil,
                                                                  stage: "llm-index-ideas")
    end.to raise_error(ArgumentError, /unknown keyword: :stage/)
  end

  describe "an LLM round" do
    let(:dedupe) do
      table = Quaack::Enclave::TableStatistics.new(name: t, reltuples: 100_000, columns: {},
                                                   column_names: %w[a c s], indexes: {})
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]), low_cardinality: [])
    end

    def test(candidates)
      Quaack::Enclave::SingleCandidateTest.run(conn, query: "SELECT * FROM t WHERE a = $1",
                                                     literal_sets: { slow: ["5"], worst: ["7"], typical: ["70000"] },
                                                     candidates:)
    end

    def llm(**) = Quaack::Enclave::IndexCandidate.new(table: t, sources: [:llm], **)

    # index-dedupe and index-test on two mechanical candidates, which the planner uses.
    def mechanical
      survivors = dedupe.filter([candidate(key: ["a"]), candidate(key: %w[a c])])
      since = described_class.record_dedupe(store, dedupe, search: :original)
      mechanical_report = test(survivors)
      described_class.record_single_candidate_test(store, mechanical_report, search: :original, dedupe:)
      [since, mechanical_report]
    end

    # Three LLM candidates: a duplicate, a GIN set aside, and one the
    # planner never uses.
    def llm_candidates = [llm(key: ["a"]), llm(key: ["c"], access_method: :gin), llm(key: ["c"])]

    it "records index-dedupe and index-test on the LLM's candidates as one llm-index-ideas record that adds them" do
      since, = mechanical
      survivors = dedupe.filter(llm_candidates)
      llm_report = test(survivors)
      expect(llm_report.results.map(&:used?)).to eq([false])

      described_class.record_llm_round(store, stage: "llm-index-ideas", search: :original, dedupe:, since:,
                                              report: llm_report)

      burndown = described_class.read(store)
      expect(burndown.dig("stages", "llm-index-ideas", "original")).to eq(
        "in" => 0, "added" => { "llm" => 3 }, "dropped" => { "duplicate" => 1, "never_used" => 1 },
        "set_aside" => 1, "out" => 0, "extra" => {}
      )
      expect(burndown.dig("stages", "index-dedupe", "original", "in")).to eq(2)
      expect(burndown.dig("stages", "index-test", "original", "out")).to eq(2)
      expect(burndown["totals"]).to eq("hypothetical_explains" => 6 + 3)
    end

    it "records the llm-index-refine round from what the llm-index-ideas round returned" do
      since, = mechanical
      after_5a5 = described_class.record_llm_round(store, stage: "llm-index-ideas", search: :original, dedupe:, since:,
                                                          report: test(dedupe.filter(llm_candidates)))
      revised = test(dedupe.filter([llm(key: %w[a s])]))
      expect(revised.results.map(&:used?)).to eq([true])

      described_class.record_llm_round(store, stage: "llm-index-refine", search: :original, dedupe:, since: after_5a5,
                                              report: revised)

      expect(described_class.read(store).dig("stages", "llm-index-refine", "original")).to eq(
        "in" => 0, "added" => { "llm" => 1 }, "dropped" => {}, "set_aside" => 0, "out" => 1, "extra" => {}
      )
    end

    it "refuses a round whose report didn't test what this round's filtering kept" do
      since, mechanical_report = mechanical
      dedupe.filter(llm_candidates)

      expect do
        described_class.record_llm_round(store, stage: "llm-index-ideas", search: :original, dedupe:, since:,
                                                report: mechanical_report)
      end.to raise_error(described_class::Error, /llm-index-ideas/)
      expect(described_class.read(store)["stages"].keys).to eq(%w[index-dedupe index-test])
    end
  end
end
