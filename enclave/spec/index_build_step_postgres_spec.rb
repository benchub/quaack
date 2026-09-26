# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/index_build"

# README 12a: `quaacks index-build` builds every distinct index from the
# 5a and step 11 rankings and the set-aside GIN/GiST/SP-GiST candidates,
# records sizes, and hides them. IndexBuild.show_only unhides one
# combination and confirms with a plain EXPLAIN that the rest are hidden.
RSpec.describe "quaacks index-build, against a real server" do
  include_context "an index search run"

  let(:spgist) do
    Quaack::Enclave::IndexStore.candidate_plain(
      Quaack::Enclave::IndexCandidate.new(table: orders, key: ["note"], access_method: :spgist, sources: [:t])
    )
  end

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)

  def ranked_run
    prepare
    run("index-search")
    entry = store.read("index_search_original")
    entry["dedupe"]["set_aside"] = [spgist]
    store.write("index_search_original", entry)
    run("index-rank")
  end

  def indexes(conn)
    conn.exec(<<~SQL).to_a
      SELECT c.relname, c.oid::int AS oid, i.indisvalid FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'public.orders'::regclass ORDER BY c.relname
    SQL
  end

  it "builds each distinct ranked and set-aside index once, records sizes, hides only its own, sends only done" do
    ranked_run

    outcome = run("index-build")

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    build = stored.read("index_build")
    ranking = stored.read("index_ranking_original")
    ddls = (ranking["top"] + [ranking["combination"]].compact).flat_map { it["ddl"] }.uniq +
           ["CREATE INDEX ON public.orders USING spgist (note)"]
    expect(build["indexes"].values.map { it["ddl"] }).to match_array(ddls)
    expect(build["indexes"].values.map { it["size"] }).to all(be_positive)
    expect(build["combinations"].keys).to include("original:top:1", "original:set_aside:1")
    expect(build["combinations"]["original:top:1"].map { build["indexes"][it]["ddl"] })
      .to eq(ranking["top"].first["ddl"])
    conn = production.connect
    rows = indexes(conn)
    ours = rows.select { build["indexes"].key?(it["relname"]) }
    expect(ours.size).to eq(ddls.size)
    expect(ours.map { it["indisvalid"] }).to all(eq("f"))
    expect(rows.reject { build["indexes"].key?(it["relname"]) }.map { it["indisvalid"] }).to eq(["t"])

    again = run("index-build")

    expect(again.stdout).to eq(%({"type":"done"}\n))
    expect(indexes(conn)).to eq(rows)
  ensure
    conn&.close
  end

  it "unhides just one combination, confirms it with EXPLAIN, and catches a hidden index the plan uses" do
    ranked_run
    run("index-build")
    build = stored.read("index_build")
    conn = production.connect
    names = build["combinations"]["original:set_aside:1"]
    sql = "SELECT note FROM public.orders WHERE note = 'n7'"
    conn.exec("SET enable_seqscan = off; SET enable_bitmapscan = off")

    used = Quaack::Enclave::IndexBuild.show_only(conn, build, "original:set_aside:1", sql:)

    expect(used).to eq(names)
    valid = indexes(conn).select { build["indexes"].key?(it["relname"]) }.to_h { [it["relname"], it["indisvalid"]] }
    expect(valid).to eq(build["indexes"].keys.to_h { [it, names.include?(it) ? "t" : "f"] })
    conn.exec("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'public.#{names.first}'::regclass")
    other = (build["indexes"].keys - names).first
    conn.exec("UPDATE pg_index SET indisvalid = true WHERE indexrelid = 'public.#{other}'::regclass")
    expect { Quaack::Enclave::IndexBuild.confirm(conn, build, [], sql:) }
      .to raise_error(Quaack::Enclave::IndexBuild::Error, "index_build_hidden_index_used")
  ensure
    conn&.close
  end

  it "builds with raised maintenance settings" do
    ranked_run
    conn = production.connect
    Quaack::Enclave::IndexBuild.build(store, conn)

    expect(conn.exec("SHOW maintenance_work_mem").getvalue(0, 0)).to eq("1GB")
    expect(conn.exec("SHOW max_parallel_maintenance_workers").getvalue(0, 0)).to eq("4")
  ensure
    conn&.close
  end
end
