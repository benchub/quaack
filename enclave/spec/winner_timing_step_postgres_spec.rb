# frozen_string_literal: true

require "json"
require_relative "support/index_search_run"

# Task 20261016-14, DESIGN.md's winner-timing: `quaacks winner-timing` runs
# the winner once more, on the slow values, with EXPLAIN (ANALYZE, BUFFERS)
# and timing on, under the same rails as measurement, apart from the
# measured runs, so the report can show where its time went.
RSpec.describe "quaacks winner-timing, against a real server" do
  include_context "an index search run"

  def run(step) = quaacks.run(step, "--run", store.run_id, env: libpq_env)

  def baselined_run
    prepare
    %w[index-search index-rank index-build baseline index-baseline].each { run(it) }
  end

  def win(label) = stored.write("selection", "top" => [{ "label" => label }], "excluded" => {}, "infinite_sets" => [])

  def add_rewrite(num, sql) = stored.write("rewrite_#{num}", "sql" => sql, "anchored_sql" => sql)

  def nodes(plan) = [plan, *plan.fetch("Plans", []).flat_map { nodes(it) }]

  def visible_count
    conn = production.connect
    names = stored.read("index_build")["indexes"].keys
    conn.exec_params("SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
                     "WHERE c.relname = ANY($1::text[]) AND i.indisvalid",
                     [PG::TextEncoder::Array.new.encode(names)]).getvalue(0, 0)
  ensure
    conn&.close
  end

  it "times the winner on the slow values under its own indexes, stores the redacted plan, sends only done" do
    baselined_run
    measured = stored.read("index_baseline")
    win("original:top:1")
    built = stored.read("index_build")["combinations"].fetch("original:top:1")

    outcome = run("winner-timing")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("winner_timing")
    expect(entry.slice("label", "result")).to eq("label" => "original:top:1", "result" => "timed")
    steps = nodes(entry["plan"].first["Plan"])
    expect(steps).to all(include("Actual Total Time" => be_a(Float), "Actual Loops" => be_a(Integer)))
    expect(steps.first).to include("Shared Hit Blocks")
    expect(steps.filter_map { it["Index Name"] }).to include(*built)
    expect(JSON.generate(entry)).not_to include(sentinels.text)
    rows = measured["combinations"]["original:top:1"].transform_values { |m| m["plans"][0][0]["Plan"]["Actual Rows"] }
    expect(rows["slow"]).not_to eq(rows["typical"])
    expect(steps.first["Actual Rows"]).to eq(rows["slow"])
    expect(stored.read("index_baseline")).to eq(measured)
    expect(visible_count).to eq("0")
  end

  it "times a rewrite that won with no new indexes on its own SQL, with every built index hidden" do
    baselined_run
    add_rewrite(1, "SELECT o.note FROM public.orders o WHERE o.note = $1 AND o.status = $2 AND o.id > 0")
    win("rewrite_1:none")

    run("winner-timing")

    entry = stored.read("winner_timing")
    expect(entry.slice("label", "result")).to eq("label" => "rewrite_1:none", "result" => "timed")
    steps = nodes(entry["plan"].first["Plan"])
    expect(steps.filter_map { it["Index Name"] }.grep(/\Aquaack_/)).to eq([])
  end

  it "records a winner that hits statement_timeout as timed_out, with no plan" do
    baselined_run
    stored.write("baseline", stored.read("baseline").merge("timeout_ms" => 100))
    add_rewrite(1, "SELECT pg_sleep(0.5), $1::text IS NULL")
    win("rewrite_1:none")

    outcome = run("winner-timing")

    expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
    expect(stored.read("winner_timing")).to eq("label" => "rewrite_1:none", "result" => "timed_out", "plan" => nil)
    expect(visible_count).to eq("0")
  end

  # The run is READ ONLY, as every measured run is: a winner that would
  # write fails, writes nothing, and costs the report only the times.
  it "records a winner whose run fails as failed, in a read-only transaction that wrote nothing" do
    baselined_run
    conn = production.connect
    conn.exec("CREATE SEQUENCE public.winner_seq")
    add_rewrite(1, "SELECT nextval('public.winner_seq'), $1::text IS NULL")
    win("rewrite_1:none")

    outcome = run("winner-timing")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(stored.read("winner_timing")).to eq("label" => "rewrite_1:none", "result" => "failed", "plan" => nil)
    expect(conn.exec("SELECT last_value, is_called FROM public.winner_seq").values).to eq([%w[1 f]])
  ensure
    conn&.close
  end

  it "records no winner, and connects to nothing, when nothing beat the original" do
    baselined_run
    win(nil)
    stored.write("selection", stored.read("selection").merge("top" => []))
    stored.write("run_server", "host" => "quaack-no-such-host.invalid", "port" => 1, "racetrack_db" => "x",
                               "arena_db" => "y")

    outcome = run("winner-timing")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(stored.read("winner_timing")).to eq("label" => nil, "result" => nil, "plan" => nil)
  end
end
