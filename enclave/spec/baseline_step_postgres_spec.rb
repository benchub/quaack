# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/measurement"
require_relative "support/catalog_shadow"

# DESIGN.md's baseline and run-discipline: `quaacks baseline` hides every built index and runs the
# original three times per literal set under RunDiscipline, recording total
# blocks and the hit/read split. Measurement is the helper index-baseline and candidate-runs reuse.
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

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([counts_then_done(sets: 3, timed_out: 0), "", 0])
    expect_no_leaks(sentinels, outcome)
    baseline = stored.read("baseline")
    expect(baseline["sets"].keys).to match_array(%w[slow worst_case typical])
    expect(baseline).not_to have_key("timed_out")
    expect(baseline["measurement_runs"]).to eq(9)
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
    top = Quaack::Enclave::Measurement.plan(measured["slow"])[0]["Plan"]
    expect(top["Shared Hit Blocks"] + top["Shared Read Blocks"]).to eq(measured["slow"]["total_blocks"])
  ensure
    conn&.close
  end

  # Task 20260930-14: the connection's search_path puts public ahead of
  # pg_catalog, and public's comparisons say no (see CatalogShadow).
  # pg_prepared_statements is still read for the parameters' types, and
  # the statement is still deallocated.
  it "binds each value with its type when public's comparison operators shadow pg_catalog's" do
    conn = production.connect
    CatalogShadow.plant(conn, :operators)
    conn.exec("SET search_path = public, pg_catalog")
    map = { "$1" => { "value" => "5", "type" => "unknown" }, "$2" => { "value" => "x", "type" => "unknown" } }
    bound = Quaack::Enclave::Redaction.binding("SELECT $1::int, $2::text", map)

    expect(Quaack::Enclave::Measurement.params(conn, bound)).to eq([{ value: "5", type: 23 }, { value: "x", type: 25 }])
    expect(conn.exec("SELECT pg_catalog.count(*) FROM pg_catalog.pg_prepared_statements").getvalue(0, 0)).to eq("0")
  ensure
    conn&.close
  end

  it "records a timed-out statement instead of blocks, with how many runs it got through" do
    built_run
    conn = production.connect

    measured = Quaack::Enclave::Measurement.measure(connection: conn, store: stored,
                                                    sql: "SELECT pg_sleep(0.3), $1::text IS NULL",
                                                    combination: nil, timeout_ms: 50)

    expect(measured["slow"]).to eq("timed_out" => true, "ran" => 1)
    expect(Quaack::Enclave::Measurement.runs(measured.merge("x" => { "runs" => [{}, {}, {}] }))).to eq(6)
  ensure
    conn&.close
  end

  # Task 20260926-32: block counts that move between runs, from a real
  # server. Each run's LIMIT comes from a function that takes one more
  # session advisory lock (allowed in READ ONLY, and kept past the
  # rollback) and returns how many it holds, so every run scans more of
  # orders than the one before.
  it "marks a set unstable when a real server's block counts move, keeping every run's redacted plan" do
    built_run
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE FUNCTION public.quaack_next_run() RETURNS bigint LANGUAGE plpgsql VOLATILE AS $$
      DECLARE n bigint;
      BEGIN
        SELECT count(*) INTO n FROM pg_catalog.pg_locks
        WHERE locktype = 'advisory' AND pid = pg_catalog.pg_backend_pid() AND classid = 7130;
        PERFORM pg_catalog.pg_advisory_lock(7130, (n + 1)::int);
        RETURN n + 1;
      END $$;
    SQL
    # One warm-up call, so the first run doesn't also read the catalog to
    # compile the function.
    conn.exec("SELECT public.quaack_next_run(); SELECT pg_catalog.pg_advisory_unlock_all()")
    sql = "SELECT count(*) FROM (SELECT o.id FROM public.orders o WHERE o.note <> $1::text AND $2::text IS NOT NULL " \
          "LIMIT public.quaack_next_run() * 1500) s"

    slow = Quaack::Enclave::Measurement.measure(connection: conn, store: stored, sql:, combination: nil,
                                                timeout_ms: 5_000)["slow"]

    totals = slow["runs"].map { it["total_blocks"] }
    expect(totals).to eq(totals.sort.uniq)
    expect(totals.size).to eq(3)
    expect(slow["stable"]).to be(false)
    expect(slow["total_blocks"]).to eq(totals.last)
    expect(slow["plans"].size).to eq(3)
    expect(slow["plans"].map { it[0]["Plan"]["Shared Hit Blocks"] + it[0]["Plan"]["Shared Read Blocks"] }).to eq(totals)
    expect(Quaack::Enclave::Measurement.plan(slow)).to eq(slow["plans"].last)
    expect(slow["plans"].to_json).not_to include(sentinels.text)
  ensure
    conn&.exec("SELECT pg_catalog.pg_advisory_unlock_all()")
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
    expect(summary["plans"].map { it[0]["Plan"]["Temp Written Blocks"] }).to eq([0, 4, 0])
    expect(Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)["plans"].size).to eq(1)
    expect(Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)["stable"]).to be(true)
  end

  it "keeps the redacted plan of the run with the most blocks, stable or not, the run its hit and read come from" do
    map = { "$1" => { "value" => "secret-7", "type" => "unknown" } }
    runs = [plan(10, 5), plan(10, 9), plan(10, 9)]
    runs.each { it[0]["Plan"]["Filter"] = "(a = 'secret-7'::text)" }
    runs[2][0]["Execution Time"] = 2.5

    summary = Quaack::Enclave::Measurement.summarize(runs, map)
    kept = Quaack::Enclave::Measurement.plan(summary)

    expect(kept[0]["Plan"]["Shared Read Blocks"]).to eq(9)
    expect(kept[0]["Execution Time"]).to eq(1.5)
    expect(kept.to_json).not_to include("secret-7")
    stable = Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)
    expect(Quaack::Enclave::Measurement.plan(stable)).to eq(plan(1, 1))
  end

  it "keeps the first run's plan for a stable set whose runs differ only in Execution Time" do
    map = { "$1" => { "value" => "secret-7", "type" => "unknown" } }
    runs = [plan(1, 1), plan(1, 1), plan(1, 1)]
    runs.each_with_index { |run, i| run[0]["Execution Time"] = [1.25, 2.5, 3.75][i] }

    summary = Quaack::Enclave::Measurement.summarize(runs, map)

    expect(summary["stable"]).to be(true)
    expect(summary["plans"].map { it[0]["Execution Time"] }).to eq([1.25])
    expect(Quaack::Enclave::Measurement.plan(summary)[0]["Execution Time"]).to eq(1.25)
  end

  it "stores each run's plan once, with no second copy of the kept plan" do
    map = { "$1" => { "value" => "secret-7", "type" => "unknown" } }

    expect(Quaack::Enclave::Measurement.summarize([plan(10, 5), plan(10, 9), plan(10, 5)], map)).not_to have_key("plan")
    expect(Quaack::Enclave::Measurement.summarize([plan(1, 1)] * 3, map)).not_to have_key("plan")
  end

  it "has no measured plan for a set that timed out or was stored without plans" do
    expect(Quaack::Enclave::Measurement.plan("timed_out" => true, "ran" => 1)).to be_nil
    expect(Quaack::Enclave::Measurement.plan("timed_out" => false, "runs" => [{ "total_blocks" => 1 }])).to be_nil
  end
end
