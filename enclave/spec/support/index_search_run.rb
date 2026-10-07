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
require_relative "production_server"

# A run ready for `quaacks index-search` and the llm-index-ideas steps after it: its
# inputs come from input, statistics, literals, classify, redact, clock-anchor, and racetrack-setup, run in-process
# against the stand-in production database, which is also the racetrack, as
# in racetrack_setup_step_postgres_spec.rb. The slow literal is a sentinel.
RSpec.shared_context "an index search run" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:select_list) { "o.note, o.status" }
  let(:query) do
    "SELECT #{select_list} FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held'"
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

  # input, statistics, classify, redact, literals, clock-anchor, run-server and racetrack-setup, in order.
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
    store.write("qualified_query", query)
    store.write("relations", [{ "schema" => "public", "name" => "orders" }])
    Quaack::Enclave::PlannerStatistics.run(store:, relations: [orders], connection: conn)
    Quaack::Enclave::PiiClassification.run(store:, config: Quaack::Enclave::Config.new({}))
  end

  def store_redacted(redacted)
    redacted.store(store)
    store.write("redacted_query", redacted.query.sql)
    store.write("redacted_plan", redacted.plan.to_h.transform_keys(&:name))
  end

  def redact_and_anchor(explain)
    redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(query), explain)
    store_redacted(redacted)
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

  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def index_search(*extra) = quaacks.run("index-search", "--run", store.run_id, *extra, env: libpq_env)
end
