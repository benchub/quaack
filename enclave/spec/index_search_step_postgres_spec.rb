# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/config"
require "quaack/enclave/index_store"
require "quaack/enclave/literal_set"
require "quaack/enclave/pii_classification"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/racetrack"
require "quaack/enclave/redaction"
require "quaack/enclave/steps/anchor"
require "quaack/enclave/store"
require "quaack/enclave/table_name"
require_relative "support/production_server"

# `quaacks index-search` (README 5 and 5a-1 to 5a-4) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler. Its
# inputs come from steps 1, 3c, 3e, 3f, 3g, 3h, and 4a, run in-process
# against the stand-in production database, which is also the racetrack, as
# in racetrack_setup_step_postgres_spec.rb. The slow literal is a sentinel.
RSpec.describe "quaacks index-search, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:query) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held'"
  end
  let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base) }

  after do
    quaacks.remove
    production.drop
  end

  def seed(conn)
    conn.exec(<<~SQL)
      CREATE TABLE public.orders (id int PRIMARY KEY, note text, status text, total int, created_at timestamptz);
      INSERT INTO public.orders
      SELECT i, CASE WHEN i % 500 = 0 THEN '#{sentinels.text}' ELSE 'n' || i END,
             (ARRAY['open', 'held', 'shipped'])[i % 3 + 1], i % 100, now() - i * interval '1 minute'
      FROM generate_series(1, 20000) AS i;
      ANALYZE public.orders;
    SQL
  end

  # Steps 1, 3c, 3f, 3g, 3e, 3h, 4 and 4a, in order.
  def prepare(racetrack_setup: true)
    conn = production.connect
    seed(conn)
    explain = JSON.parse(conn.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{query}").getvalue(0, 0))
    capture_and_classify(conn, explain)
    redact_and_anchor(explain)
    set_up_racetrack(conn, racetrack_setup)
  ensure
    conn&.close
  end

  def capture_and_classify(conn, explain)
    store.write("plan", explain)
    store.write("relations", [{ "schema" => "public", "name" => "orders" }])
    Quaack::Enclave::PlannerStatistics.run(store:, relations: [orders], connection: conn)
    Quaack::Enclave::PiiClassification.run(store:, config: Quaack::Enclave::Config.new({}))
  end

  def redact_and_anchor(explain)
    redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(query), explain)
    redacted.store(store)
    store.write("redacted_query", redacted.query.sql)
    Quaack::Enclave::LiteralSet.run(store:, sql: redacted.query.sql)
    Quaack::Enclave::Steps::Anchor.call(store:)
  end

  def set_up_racetrack(conn, racetrack_setup)
    store.write("clock_anchor", "2026-09-23T22:15:00.123456Z")
    store.write("run_server", "host" => production.host, "port" => production.port,
                              "racetrack_db" => production.name, "arena_db" => "quaack_arena_not_made_yet")
    Quaack::Enclave::Racetrack.setup(store:, connection: conn)
    store.write("racetrack_setup", true) if racetrack_setup
  end

  def libpq_env
    ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge("PGUSER" => production.user,
                                                   "PGPASSWORD" => production.password)
  end

  def index_search(*extra) = quaacks.run("index-search", "--run", store.run_id, *extra, env: libpq_env)
  def error_line(rule) = %({"type":"error","step":"index-search","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("index_search_original")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  def sources(candidate) = candidate.sources.map(&:to_s).sort

  def restored_search(entry)
    Quaack::Enclave::IndexStore.dedupe(
      entry["dedupe"], statistics: Quaack::Enclave::PlannerStatistics.load(stored).statistics,
                       low_cardinality: Quaack::Enclave::PiiClassification.load(stored).low_cardinality
    )
  end

  it "runs the mechanical search, saves it per search, and prints only DONE" do
    prepare

    outcome = index_search

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("index_search_original")
    search = restored_search(entry)
    expect(search.proposals.map { it.sources.to_a.sort }).to include(%i[parse plan])
    expect(search.considered).to eq(search.proposals.size + search.set_aside.size + search.drops.size)
    tested = entry["results"].map { Quaack::Enclave::IndexStore.candidate(it["candidate"]) }
    expect(tested).to eq(search.proposals)
    expect(entry["results"].map { it["candidate"]["sources"] }).to eq(search.proposals.map { sources(it) })
    expect(entry["baseline"].keys).to eq(%w[slow worst_case typical])
    used = entry["results"].find { it["plans"].values.any? { |plan| plan["used"] } }
    expect(used["size"]).to be_a(Integer).and be_positive
    expect(used["plans"]["slow"]["total_cost"]).to be < entry["baseline"]["slow"]
  end

  it "accepts --search original, and refuses any other search" do
    prepare
    expect(index_search("--search", "original").stdout).to eq(%({"type":"done"}\n))

    outcome = index_search("--search", "rewrite_1")
    expect([outcome.stdout, outcome.status.exitstatus]).to eq([error_line("index_search_unknown_search"), 70])
  end

  it "refuses a run whose racetrack isn't set up, storing nothing" do
    prepare(racetrack_setup: false)

    expect_failed(index_search, "index_search_no_racetrack_setup")
  end

  it "fails the plan gate with its rule when the racetrack plans differently, storing nothing" do
    prepare
    conn = production.connect
    conn.exec("CREATE INDEX ON public.orders (note)")
    conn.close

    expect_failed(index_search, "plan_gate_mismatch_likely_stale_statistics")
  end
end
