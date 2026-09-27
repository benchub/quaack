# frozen_string_literal: true

require "quaack/enclave/step_nine"

# Step 9 end to end: build the scenarios, run the 9c guard, and run every
# scenario through the 9d comparison for each candidate.
RSpec.describe Quaack::Enclave::StepNine do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.orders (id integer PRIMARY KEY, status text NOT NULL, qty integer);
    SQL
  end

  let(:original) { "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49' AND o.qty <> 5" }

  def run(*candidates) = described_class.run(conn, original, candidates)

  it "passes an equivalent candidate and disproves others, naming the scenario" do
    report = run("SELECT o.id FROM fx.orders o WHERE o.qty <> 5 AND o.status = 'SENTINEL_49'",
                 "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49'",
                 "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49' AND o.qty IS DISTINCT FROM 5")
    expect(report.results.map { |r| [r.passed, r.scenario] }).to eq([[true, nil], [false, :s1], [false, :s2]])
    expect(report.results[1].rule).to eq(:row_count)
    expect(report.untested).to eq([])
  end

  it "reports a candidate that fails to run as disproved, with the runner's rule" do
    report = run("SELECT o.id FROM fx.orders o WHERE o.qty / 0 = 1")
    expect(report.results.map { |r| [r.passed, r.scenario, r.rule] }).to eq([[false, :s1, :query_failed]])
  end

  it "reports nothing but shapes, rules, and scenario names, though the fixture holds the sentinel" do
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(original))
    expect(builder.build[:s1].flat_map(&:values)).to include("SENTINEL_49")
    report = run("SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49'")
    expect(report.to_h.to_s).not_to include("SENTINEL_49")
    expect(report.inspect).not_to include("SENTINEL_49")
  end

  it "tests an ORM keyset page, passing the expanded form and disproving one that drops the keyset" do
    keyset = "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49' AND (o.qty, o.id) < (7, 900) " \
             "ORDER BY o.qty DESC, o.id DESC LIMIT 10"
    report = described_class.run(
      conn, keyset,
      ["SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49' AND (o.qty < 7 OR (o.qty = 7 AND o.id < 900)) " \
       "ORDER BY o.qty DESC, o.id DESC LIMIT 10",
       "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_49' ORDER BY o.qty DESC, o.id DESC LIMIT 10"]
    )
    expect(report.untested).to eq([])
    expect(report.results.map { |r| [r.passed, r.scenario] }).to eq([[true, nil], [false, :s1]])
    expect(report.to_h.to_s).not_to include("SENTINEL_49")
  end

  it "disproves a keyset candidate that changes only the tie-breaker value" do
    keyset = "SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) < (7, 900) ORDER BY o.qty DESC, o.id DESC LIMIT 10"
    report = described_class.run(
      conn, keyset,
      ["SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) < (7, 901) ORDER BY o.qty DESC, o.id DESC LIMIT 10",
       "SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) < (7, 899) ORDER BY o.qty DESC, o.id DESC LIMIT 10",
       "SELECT o.id FROM fx.orders o WHERE (o.qty, o.id) <= (7, 899) ORDER BY o.qty DESC, o.id DESC LIMIT 10"]
    )
    expect(report.results.map(&:passed)).to eq([false, false, true])
  end

  it "counts the groups left out because they collide on a unique key" do
    expect(run.dropped).to eq(0)
    conn.exec("CREATE TABLE fx.tags (id integer PRIMARY KEY, name text NOT NULL UNIQUE, qty integer)")
    # The hit and qty's near miss both need name 'a', so the near miss
    # collides with the hit on the unique name.
    report = described_class.run(conn, "SELECT t.id FROM fx.tags t WHERE t.name = 'a' AND t.qty <> 5", [])
    expect(report.dropped).to be_positive
  end
end
