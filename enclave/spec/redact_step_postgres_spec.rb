# frozen_string_literal: true

require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks redact --run <run ID>` (DESIGN.md 3g) the way the jump server runs
# it: the installed quaacks in its own process, outside Bundler. It reads the
# run's qualified_query and plan entries, here a real EXPLAIN ANALYZE of a
# query whose literals are sentinels, and needs no production connection.
RSpec.describe "quaacks redact" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) do
    "SELECT o.id FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.code > #{sentinels.number}"
  end
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("qualified_query", query)
      store.write("plan", explain)
    end
  end

  after do
    quaacks.remove
    production.drop
  end

  def explain
    conn = production.connect
    conn.exec("CREATE TABLE public.orders (id int, note text, code bigint)")
    JSON.parse(conn.exec("EXPLAIN (ANALYZE, FORMAT JSON) #{query}").getvalue(0, 0))
  ensure
    conn&.close
  end

  def no_libpq_env = ENV.keys.grep(/\APG/).to_h { [it, nil] }
  def redact(run_id = store.run_id) = quaacks.run("redact", "--run", run_id, env: no_libpq_env)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def entries = %w[placeholder_map placeholder_shapes redacted_query redacted_plan]

  it "stores the redacted query and plan with placeholders, and the map, printing only DONE" do
    outcome = redact

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(stored.read("redacted_query"))
      .to eq("SELECT o.id FROM public.orders o WHERE o.note = $1 AND o.code > $2")
    expect(stored.read("placeholder_map").transform_values { it["value"] })
      .to eq("$1" => sentinels.text, "$2" => sentinels.number.to_s)
    shapes = stored.read("placeholder_shapes")
    expect([shapes.keys, shapes["$1"]["rows"]["status"]]).to eq([%w[$1 $2], "found"])
    plan = stored.read("redacted_plan")
    expect(JSON.generate(plan["explain"])).to include("$1", "$2")
    expect(plan.values_at("masked", "dropped")).to eq([0, 0])
    expect_no_leaks(sentinels, outcome)
  end

  it "keeps the sentinels out of the redacted entries, and the leak check would catch them" do
    redact

    redacted = JSON.generate(stored.read("redacted_query")) + JSON.generate(stored.read("redacted_plan"))
    expect(LeakCheck.findings(sentinels, stdout: redacted)).to eq([])
    held = JSON.generate(stored.read("placeholder_map"))
    expect(LeakCheck.findings(sentinels, stdout: held).join("\n")).to include(sentinels.needles[:text])
  end

  it "refuses a run with no plan entry as missing_plan, storing nothing" do
    fresh = Quaack::Enclave::Store.create(base: quaacks.store_base)
    fresh.write("qualified_query", query)

    outcome = redact(fresh.run_id)

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"redact","rule":"missing_plan"}\n), "", 70])
    expect(entries.map { fresh.entry?(it) }).to all(be(false))
  end

  it "refuses a query it can't redact by its rule, storing nothing" do
    store.write("qualified_query", "SELECT o.id FROM public.orders o WHERE o.id = $1 AND o.note = '#{sentinels.text}'")

    outcome = redact

    expect([outcome.stdout, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"redact","rule":"query_has_parameters"}\n), 70])
    expect(entries.map { stored.entry?(it) }).to all(be(false))
    expect_no_leaks(sentinels, outcome)
  end
end
