# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "quaack/enclave/store"

# `quaacks intake` the way the operator runs it on the jump server: exe/quaacks
# in its own process, with the query in one file and the EXPLAIN output in
# another, captured from the test harness's Postgres just now. HOME is a
# temporary directory, so the runs land under it, never in the real
# ~/.quaack.
RSpec.describe "quaacks intake, from a real EXPLAIN" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaacks") }
  let(:home) { Dir.mktmpdir("quaack-intake-home") }
  # Where the operator keeps the input files. Its name holds a sentinel, so
  # a path that got echoed would show.
  let(:inputs) { File.join(home, "sentinel-3c9e41-inputs").tap { Dir.mkdir(it) } }
  let(:runs_base) { File.join(home, ".quaack", "runs") }
  # Literals that stand in for production values.
  let(:sentinels) { %w[sentinel-3c9e41-email sentinel-3c9e41-name sentinel-3c9e41-inputs] }
  let(:query) do
    "SELECT c.id, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
      "WHERE c.email = 'sentinel-3c9e41-email' OR c.name = 'sentinel-3c9e41-name' ORDER BY o.total_cents"
  end

  after { FileUtils.rm_rf(home) }

  def explain(how, settings: [])
    conn = test_database.connection
    conn.transaction do
      settings.each { |s| conn.exec("SET LOCAL #{s}") }
      conn.exec("#{how} #{query}").column_values(0).join("\n")
    end
  end

  def input(name, text) = File.join(inputs, name).tap { File.write(it, text) }

  def quaacks_intake(plan_text, *extra)
    run_exe({ "HOME" => home }, exe, "intake", "--query", input("query.sql", query),
            "--plan", input("plan.json", plan_text), "--server", "prod-db-3", *extra)
  end

  # Runs Ruby in a child process, as run_ruby does, with env added to its environment.
  def run_exe(env, *) = Open3.capture3(env, RbConfig.ruby, *)

  def runs = File.directory?(runs_base) ? Dir.children(runs_base) : []

  def expect_no_sentinels(*streams)
    streams.each { |text| sentinels.each { expect(text).not_to include(it) } }
  end

  it "takes EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) and prints only the new run's ID" do
    plan_text = explain("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)", settings: ["enable_hashjoin = off"])
    expect(plan_text).to include("sentinel-3c9e41-email")

    out, err, status = quaacks_intake(plan_text, "--captured-at", "2026-09-23T15:15:00-07:00")

    expect(status.exitstatus).to eq(0), out
    expect(err).to eq("")
    expect(runs.size).to eq(1)
    expect(out).to eq(%({"type":"run","run_id":"#{runs[0]}"}\n{"type":"done"}\n))
    expect_no_sentinels(out, err)

    store = Quaack::Enclave::Store.open(runs[0], base: runs_base)
    expect(store.read("query")).to eq(query)
    expect(store.read("plan")).to eq(JSON.parse(plan_text))
    expect(store.read("plan")[0]["Settings"]).to eq("enable_hashjoin" => "off")
    expect(store.read("server")).to eq("prod-db-3")
    expect(store.read("clock_anchor")).to eq("2026-09-23T22:15:00.000000Z")
  end

  it "takes a plan with every setting at its default, which has empty Settings" do
    plan_text = explain("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)")
    expect(JSON.parse(plan_text)[0]["Settings"]).to eq({})

    out, _err, status = quaacks_intake(plan_text)

    expect(status.exitstatus).to eq(0), out
    expect(runs.size).to eq(1)
  end

  it "takes a plan from ANALYZE with TIMING OFF" do
    out, _err, status = quaacks_intake(explain("EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, FORMAT JSON)"))

    expect(status.exitstatus).to eq(0), out
    expect(runs.size).to eq(1)
  end

  it "refuses a query it doesn't support without echoing it, and leaves no run" do
    plan_text = explain("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)")
    input("query.sql", "#{query} FOR UPDATE")
    out, err, status = run_exe({ "HOME" => home }, exe, "intake", "--query", File.join(inputs, "query.sql"),
                               "--plan", input("plan.json", plan_text), "--server", "prod-db-3")

    expect(out).to eq(%({"type":"error","step":"intake","rule":"unsupported_construct"}\n))
    expect(err).to eq("")
    expect(status.exitstatus).to eq(70)
    expect_no_sentinels(out, err)
    expect(runs).to eq([])
  end

  {
    "EXPLAIN (FORMAT JSON)" => "plan_not_analyzed",
    "EXPLAIN (BUFFERS, SETTINGS, FORMAT JSON)" => "plan_not_analyzed",
    "EXPLAIN (ANALYZE, BUFFERS OFF, SETTINGS, FORMAT JSON)" => "plan_no_buffers",
    "EXPLAIN (ANALYZE, BUFFERS, SETTINGS)" => "plan_not_json"
  }.each do |how, rule|
    it "refuses the output of #{how} as #{rule}, and leaves no run" do
      plan_text = explain(how)
      expect(plan_text).to include("sentinel-3c9e41-email")

      out, err, status = quaacks_intake(plan_text)

      expect(out).to eq(%({"type":"error","step":"intake","rule":"#{rule}"}\n))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(70)
      expect_no_sentinels(out, err)
      expect(runs).to eq([])
    end
  end
end
