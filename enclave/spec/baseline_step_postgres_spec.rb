# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/measurement"

# DESIGN.md 13 and 12b: `quaacks baseline` hides every built index and runs the
# original three times per literal set under RunDiscipline, recording total
# blocks and the hit/read split. Measurement is the helper 13a and 14 reuse.
RSpec.describe "quaacks baseline, against a real server" do
  include_context "an index search run"

  def run(step) = quaacks.run(step, "--run", store.run_id, env: libpq_env)

  def built_run
    prepare
    run("index-search")
    run("index-rank")
    run("index-build")
  end

  def plan(shared_hit, shared_read, temp_written: 0)
    [{ "Plan" => { "Node Type" => "Seq Scan", "Shared Hit Blocks" => shared_hit, "Shared Read Blocks" => shared_read,
                   "Local Hit Blocks" => 1, "Local Read Blocks" => 2, "Temp Read Blocks" => 3,
                   "Temp Written Blocks" => temp_written }, "Execution Time" => 1.5 }]
  end

  it "runs the original three times per set with every built index hidden, stores blocks, sends only done" do
    built_run
    shown = production.connect
    build = stored.read("index_build")
    Quaack::Enclave::IndexBuild.set_valid(shown, build["indexes"].keys, true, schemas: Quaack::Enclave::IndexBuild.schemas(build))
    shown.close

    outcome = run("baseline")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    baseline = stored.read("baseline")
    expect(baseline["sets"].keys).to match_array(%w[slow worst_case typical])
    expect(baseline["timed_out"]).to eq([])
    baseline["sets"].each_value do |m|
      expect(m["timed_out"]).to be(false)
      expect(m["runs"].size).to eq(3)
      m["runs"].each { expect(it["total_blocks"]).to eq(it["hit"] + it["read"]) }
      expect(m["runs"].map { it["total_blocks"] }).to all(be_positive)
      expect(m["total_blocks"]).to eq(m["runs"].map { it["total_blocks"] }.max)
    end
    expect(baseline["timeout_ms"]).to be_between(5_000, 300_000)
    conn = production.connect
    names = stored.read("index_build")["indexes"].keys
    valid = conn.exec_params("SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
                             "WHERE c.relname = ANY($1::text[]) AND i.indisvalid",
                             [PG::TextEncoder::Array.new.encode(names)]).getvalue(0, 0)
    expect(valid).to eq("0")
  ensure
    conn&.close
  end

  it "measures a combination with its indexes visible, so it touches fewer blocks than the baseline" do
    built_run
    run("baseline")
    conn = production.connect
    sql = stored.read("anchored_query")

    measured = Quaack::Enclave::Measurement.measure(connection: conn, store: stored, sql:,
                                                    combination: "original:top:1", timeout_ms: 5_000)

    expect(measured["slow"]["total_blocks"]).to be < stored.read("baseline")["sets"]["slow"]["total_blocks"]
  ensure
    conn&.close
  end

  it "records a timed-out statement instead of blocks" do
    built_run
    conn = production.connect

    measured = Quaack::Enclave::Measurement.measure(connection: conn, store: stored,
                                                    sql: "SELECT pg_sleep(0.3), $1::text IS NULL",
                                                    combination: nil, timeout_ms: 50)

    expect(measured["slow"]).to eq("timed_out" => true)
  ensure
    conn&.close
  end

  it "sums every block kind, marks moving counts unstable with each run's redacted plan, and keeps the max" do
    map = { "$1" => { "value" => "secret-7", "type" => "unknown" } }
    runs = [plan(10, 5), plan(10, 5, temp_written: 4), plan(10, 5)]

    summary = Quaack::Enclave::Measurement.summarize(runs, map)

    expect(summary["runs"].map { it["total_blocks"] }).to eq([21, 25, 21])
    expect(summary["runs"].first.slice("hit", "read")).to eq("hit" => 11, "read" => 10)
    expect(summary["stable"]).to be(false)
    expect(summary["total_blocks"]).to eq(25)
    expect(summary["plans"].size).to eq(3)
    expect(Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)).not_to have_key("plans")
    expect(Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)["stable"]).to be(true)
  end
end
