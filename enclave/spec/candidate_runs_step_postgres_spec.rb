# frozen_string_literal: true

require_relative "support/index_search_run"

# DESIGN.md's candidate-runs and run-discipline: `quaacks candidate-runs` measures each surviving rewrite
# with no extra indexes and under each of its index combinations, with the
# baseline's timeout, drops timed-out runs and counts them.
RSpec.describe "quaacks candidate-runs, against a real server" do
  include_context "an index search run"

  let(:rewrite) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end

  def run(step, *extra) = quaacks.run(step, "--run", store.run_id, *extra, env: libpq_env)

  def add_rewrite(num, sql, survived: true, pruned: false)
    stored.write("rewrite_#{num}", "sql" => sql)
    stored.write("rewrite_survived_#{num}", "survived" => survived)
    stored.write("rewrite_pruned_#{num}", "discarded" => pruned)
  end

  def valid_count(names)
    conn = production.connect
    conn.exec_params("SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
                     "WHERE c.relname = ANY($1::text[]) AND i.indisvalid",
                     [PG::TextEncoder::Array.new.encode(names)]).getvalue(0, 0)
  ensure
    conn&.close
  end

  it "measures each surviving rewrite bare and under each of its combinations, sends only done" do
    prepare
    add_rewrite(1, rewrite)
    add_rewrite(2, rewrite, pruned: true)
    add_rewrite(3, rewrite, survived: false)
    run("index-search", "--search", "rewrite_1")
    run("index-rank", "--search", "rewrite_1")
    run("index-search")
    run("index-rank")
    run("index-build")
    run("baseline")
    build = stored.read("index_build")
    combos = build["combinations"].keys.grep(/\Arewrite_1:/)
    expect(combos).not_to be_empty

    outcome = run("candidate-runs")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("candidate_runs")
    expect(entry["candidates"].keys).to eq(["rewrite_1"])
    runs = entry["candidates"]["rewrite_1"]
    expect(runs.keys).to match_array(["none", *combos])
    runs.each_value do |sets|
      expect(sets.keys).to match_array(%w[slow worst_case typical])
      sets.each_value { expect(it["runs"].size).to eq(3) }
    end
    best = combos.map { runs[it]["slow"]["total_blocks"] }.min
    expect(best).to be < runs["none"]["slow"]["total_blocks"]
    expect(entry["timed_out"]).to eq([])
    expect(entry["timed_out_count"]).to eq(0)
    expect(valid_count(build["indexes"].keys)).to eq("0")

    # DESIGN.md's blocks-metric and minimax, end to end: minimax reads these real runs.
    run("index-baseline")
    expect(run("minimax").stdout).to eq(%({"type":"done"}\n))
    verdicts = stored.read("minimax")["verdicts"]
    expect(verdicts.keys).to include("rewrite_1:none", *combos)
    best_combo = combos.min_by { runs[it]["slow"]["total_blocks"] }
    expect(verdicts[best_combo]["slow"]).to eq("better")
  end

  it "drops a candidate that times out and counts it" do
    prepare
    run("index-search")
    run("index-rank")
    run("index-build")
    run("baseline")
    stored.write("baseline", stored.read("baseline").merge("timeout_ms" => 100))
    add_rewrite(1, "SELECT pg_sleep(0.5), $1::text IS NULL")
    add_rewrite(2, rewrite)
    # rewrite_20's combination shares rewrite_2's prefix but isn't rewrite_2's.
    build = stored.read("index_build")
    stored.write("index_build", build.merge("combinations" => build["combinations"].merge("rewrite_20:top:1" => [])))

    outcome = run("candidate-runs")

    expect(outcome.stdout).to eq(%({"type":"done"}\n))
    entry = stored.read("candidate_runs")
    expect(entry["candidates"].keys).to eq(["rewrite_2"])
    expect(entry["candidates"]["rewrite_2"].keys).to eq(["none"])
    expect(entry["timed_out"]).to eq(["rewrite_1:none"])
    expect(entry["timed_out_count"]).to eq(1)
  end

  # DESIGN.md's clock-anchor: baseline runs the candidate's anchored_sql, so it reads the
  # anchored clock. Here that clock is years back, and only the real clock
  # makes the candidate sleep past the timeout.
  it "measures the candidate on the anchored clock" do
    prepare
    run("index-search")
    run("index-rank")
    run("index-build")
    run("baseline")
    stored.write("baseline", stored.read("baseline").merge("timeout_ms" => 100))
    conn = production.connect
    conn.exec("CREATE OR REPLACE FUNCTION quaack.clock_anchor() RETURNS pg_catalog.timestamptz " \
              "LANGUAGE sql IMMUTABLE AS $$SELECT '2000-01-01 00:00:00+00'::pg_catalog.timestamptz$$")
    conn.close
    sleepy = "SELECT pg_sleep(CASE WHEN %s < '2001-01-01' THEN 0 ELSE 0.5 END), $1::text IS NULL"
    add_rewrite(1, format(sleepy, "now()"))
    stored.write("rewrite_1", stored.read("rewrite_1").merge("anchored_sql" => format(sleepy, "quaack.clock_anchor()")))

    run("candidate-runs")

    entry = stored.read("candidate_runs")
    expect([entry["candidates"].keys, entry["timed_out"]]).to eq([["rewrite_1"], []])
  end
end
