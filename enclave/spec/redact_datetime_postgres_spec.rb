# frozen_string_literal: true

require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# 20261008-53 item 2: Postgres prints a date or timestamp in a plan in its own
# format, such as '2026-01-01 00:00:00' for '2026-01-01'. quaacks redact asks
# production to print each string placeholder the way a plan would, so the
# plan's literal gets its $n and the placeholder its row counts.
RSpec.describe "quaacks redact, with dates and timestamps" do
  let(:events) { <<~SQL }
    CREATE TABLE public.events (id int, created_at timestamp, seen_at timestamptz, day date, note text);
    INSERT INTO public.events SELECT g, '2025-12-01'::timestamp + g * interval '1 day',
      '2025-12-01'::timestamptz + g * interval '1 day', '2025-12-01'::date + g, 'n' || g
      FROM generate_series(1, 100) g;
  SQL
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) do
    "SELECT e.id FROM public.events e WHERE e.created_at >= '2026-01-01' AND e.seen_at < '2026-02-01' " \
      "AND e.day <> 'Mar 3 2026' AND e.note <> '#{sentinels.text}'"
  end
  let(:printed) { ["2026-01-01 00:00:00", "2026-02-01 00:00:00", "2026-03-03"] }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("qualified_query", query)
      store.write("plan", explain)
    end
  end

  after do
    quaacks.remove
    production.drop
  end

  def explain(settings = {})
    conn = production.connect
    settings.each { conn.exec_params("SELECT pg_catalog.set_config($1, $2, false)", it) }
    @made ||= conn.exec(events)
    JSON.parse(conn.exec("EXPLAIN (ANALYZE, FORMAT JSON) #{query}").getvalue(0, 0))
  ensure
    conn&.close
  end

  def env = production.quaacks_env(quaacks.home)

  def redact = quaacks.run("redact", "--run", store.run_id, env:)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  it "gives each date and timestamp literal in the plan its placeholder, with row counts" do
    outcome = redact

    expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
    plan = stored.read("redacted_plan")
    expect(plan["explain"][0]["Plan"]["Filter"])
      .to include("$1::timestamp without time zone", "$2::timestamp with time zone", "$3::date")
    expect(plan["masked"]).to eq(0)
    rows = stored.read("placeholder_shapes").values_at("$1", "$2", "$3").map { it["rows"] }
    expect(rows.map { [it["status"], it["estimated_rows"].class, it["actual_rows"].is_a?(Numeric)] })
      .to eq([["found", Integer, true]] * 3)
  end

  it "prints the values under inventory's TimeZone and DateStyle, as the input EXPLAIN did" do
    settings = { "TimeZone" => "America/New_York", "DateStyle" => "SQL, DMY" }
    store.write("inventory", { "settings" => settings })
    store.write("plan", explain(settings))

    outcome = redact

    expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
    plan = stored.read("redacted_plan")
    expect(plan["explain"][0]["Plan"]["Filter"]).to include("$2::timestamp with time zone")
    expect(plan["masked"]).to eq(0)
    rows = stored.read("placeholder_shapes")["$2"]["rows"]
    expect([rows["status"], rows["estimated_rows"].class]).to eq(["found", Integer])
  end

  it "keeps the printed values out of all it sends or shares, and the check would catch them" do
    outcome = redact

    out = [outcome.stdout, outcome.stderr,
           *%w[redacted_query redacted_plan placeholder_shapes].map { JSON.generate(stored.read(it)) }].join
    expect(printed.select { out.include?(it) }).to eq([])
    planted = out + JSON.generate(store.read("plan"))
    expect(printed.select { planted.include?(it) }).to eq(printed)
    expect_no_leaks(sentinels, outcome)
  end
end
