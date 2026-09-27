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

  it "builds the unused low-cardinality B-tree candidates 5a-4 set aside (20260927-11)" do
    ranked_run
    btree = Quaack::Enclave::IndexCandidate.new(table: orders, key: %w[status total], sources: [:parse])
    entry = store.read("index_search_original")
    entry["set_aside"] = [Quaack::Enclave::IndexStore.candidate_plain(btree)]
    store.write("index_search_original", entry)

    expect(run("index-build").stdout).to eq(%({"type":"done"}\n))

    build = stored.read("index_build")
    expect(build["combinations"]["original:set_aside:2"].map { build["indexes"][it]["ddl"] }).to eq([btree.to_ddl])
    expect(build["indexes"][build["combinations"]["original:set_aside:2"].first]["size"]).to be_positive
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

  it "never hides a primary key, a user unique index even named quaack_, or a user index not named quaack_" do
    prepare
    conn = production.connect
    conn.exec("CREATE UNIQUE INDEX quaack_x ON public.orders (id, note)")
    conn.exec("CREATE INDEX user_note ON public.orders (note)")
    pkey = conn.exec("SELECT conname FROM pg_constraint WHERE conrelid = 'public.orders'::regclass AND contype = 'p'")
               .getvalue(0, 0)

    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_x", pkey, "user_note"], false, schemas: "public")

    expect(indexes(conn).select { %W[quaack_x #{pkey} user_note].include?(it["relname"]) }.map { it["indisvalid"] })
      .to eq(%w[t t t])
    conn.exec("CREATE INDEX quaack_y ON public.orders (note)")
    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_y"], false, schemas: "public")
    expect(indexes(conn).find { it["relname"] == "quaack_y" }["indisvalid"]).to eq("f")
  ensure
    conn&.close
  end

  it "hides and reads validity by schema and name, leaving a same-named index in another schema alone" do
    prepare
    conn = production.connect
    conn.exec("CREATE SCHEMA other; CREATE TABLE other.orders (note text)")
    conn.exec("CREATE INDEX quaack_y ON public.orders (note); CREATE INDEX quaack_y ON other.orders (note)")

    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_y"], false, schemas: "public")

    other = conn.exec("SELECT indisvalid FROM pg_index WHERE indexrelid = 'other.quaack_y'::regclass").getvalue(0, 0)
    expect(other).to eq("t")
    build = { "indexes" => { "quaack_y" => { "ddl" => "CREATE INDEX ON public.orders (note)" } } }
    expect(Quaack::Enclave::IndexBuild.valid_names(conn, build)).to eq([])
  ensure
    conn&.close
  end

  it "refuses unqualified DDL" do
    prepare
    conn = production.connect
    expect { Quaack::Enclave::IndexBuild.create(conn, "quaack_z", "CREATE INDEX ON orders (note)") }
      .to raise_error(Quaack::Enclave::IndexBuild::Error, "index_build_unqualified")
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
