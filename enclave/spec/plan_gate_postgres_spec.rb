# frozen_string_literal: true

require "json"
require "pg_query"
require "tmpdir"
require "quaack/enclave/clock_anchoring"
require "quaack/enclave/plan_gate"
require "quaack/enclave/racetrack"
require "quaack/enclave/redaction"
require "quaack/enclave/store"

# DESIGN.md 5: the racetrack's plan for the original query with the slow
# literals must match the step 1 plan. The racetrack here is also the
# "production" server the step 1 plan comes from, so the two match until an
# example changes the racetrack's statistics after the capture.
RSpec.describe Quaack::Enclave::PlanGate do
  let(:conn) { racetrack_and_arena.racetrack.connection }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  around do |example|
    Dir.mktmpdir("quaack-plan-gate") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  # 'failed' is 1% of orders, so the planner reads it through the
  # (status, created_at) index.
  let(:query) do
    "SELECT o.id, o.total_cents FROM public.orders o " \
      "WHERE o.status = 'failed' AND o.created_at > now() - interval '400 days'"
  end

  # Step 1, 3g, 3h, and 4a, the way the run does them. Returns the SQL
  # step 5 explains: redacted and anchored.
  def prepare_run(sql = query)
    explain = explain_json("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{sql}")
    store.write("plan", explain)
    store.write("clock_anchor", "2026-06-01T00:00:00Z")
    Quaack::Enclave::Racetrack.setup(store:, connection: conn)
    Quaack::Enclave::ClockAnchoring.anchor(redacted_sql(sql, explain), explain.first["Settings"]).sql
  end

  def redacted_sql(sql, explain)
    redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(sql), explain)
    redacted.store(store)
    redacted.query.sql
  end

  def explain_json(sql) = JSON.parse(conn.exec(sql).getvalue(0, 0))

  # Makes 'failed' most of the table, as a backup restored after the
  # statistics changed would, so the planner reads the whole table.
  def make_statistics_stale
    conn.exec("UPDATE public.orders SET status = 'failed' WHERE id % 10 <> 0")
    conn.exec("ANALYZE public.orders")
  end

  def refusal(sql)
    described_class.check(store:, connection: conn, sql:)
    nil
  rescue described_class::Error => e
    e
  end

  def node_types(explain)
    walk = ->(node) { [node["Node Type"], *node.fetch("Plans", []).flat_map(&walk)] }
    walk.call(explain.first["Plan"])
  end

  it "passes when the racetrack plans the anchored query the way step 1 did" do
    sql = prepare_run

    expect(sql).to include("quaack.clock_anchor()")
    expect(described_class.check(store:, connection: conn, sql:)).to be_nil
  end

  it "refuses SQL that doesn't bind to the stored placeholder map" do
    sql = prepare_run

    expect { described_class.check(store:, connection: conn, sql: "#{sql} AND o.id = $9") }
      .to raise_error(Quaack::Enclave::Redaction::Error)
  end

  it "passes for a query with no clock function or literal" do
    sql = prepare_run("SELECT c.id FROM public.customers c ORDER BY c.created_at DESC LIMIT 5")

    expect(described_class.check(store:, connection: conn, sql:)).to be_nil
  end

  it "aborts when the racetrack's statistics make it plan differently, naming stale statistics" do
    sql = prepare_run
    make_statistics_stale
    racetrack = JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) #{query}").getvalue(0, 0))
    expect(node_types(racetrack)).to include("Seq Scan")
    expect(node_types(store.read("plan"))).not_to include("Seq Scan")

    error = refusal(sql)
    expect(error.rule).to eq("plan_gate_mismatch_likely_stale_statistics")
    expect(error.message).to include("plan_gate_mismatch_likely_stale_statistics").and include("statistics")
  end

  it "prepares each placeholder with its literal's type (e2e 020, 031)" do
    sql = prepare_run("SELECT o.id FROM public.orders o WHERE o.created_at::date > now()::date - 7 " \
                      "AND o.id <> 4242.0")

    expect(described_class.check(store:, connection: conn, sql:)).to be_nil
  end

  it "explains with the slow literals" do
    sql = prepare_run("SELECT o.id FROM public.orders o WHERE o.status = 'failed'")
    make_statistics_stale
    conn.exec("UPDATE public.orders SET status = 'held' WHERE id % 10 = 0")
    conn.exec("ANALYZE public.orders")
    # 'failed' is now common and 'held' rare, so only the slow literal,
    # 'failed', gives step 1's new plan, a seq scan.
    store.write("plan", JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) SELECT o.id FROM public.orders o " \
                                             "WHERE o.status = 'failed'").getvalue(0, 0)))
    held = JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) SELECT o.id FROM public.orders o " \
                                "WHERE o.status = 'held'").getvalue(0, 0))
    expect(node_types(store.read("plan"))).to include("Seq Scan")
    expect(node_types(held)).not_to include("Seq Scan")

    expect(described_class.check(store:, connection: conn, sql:)).to be_nil
  end

  it "aborts when a plan can't be compared, rather than passing it" do
    sql = prepare_run
    plan = store.read("plan")
    plan.first["Plan"]["Filter"] = "(status = 'x' ; DROP TABLE t)"
    store.write("plan", plan)

    expect(refusal(sql)&.rule).to eq("plan_gate_not_comparable")
  end

  it "aborts on a stored plan that isn't EXPLAIN output" do
    sql = prepare_run
    store.write("plan", { "Plan" => {} })

    expect(refusal(sql)&.rule).to eq("plan_gate_bad_plan")
  end

  describe "the trust boundary" do
    let(:sentinel) { "SENTINEL-5f3a-failed" }

    it "never puts a literal in the abort message" do
      conn.exec("UPDATE public.orders SET status = '#{sentinel}' WHERE id % 100 = 0")
      conn.exec("ANALYZE public.orders")
      sentinel_query = "SELECT o.id FROM public.orders o WHERE o.status = '#{sentinel}'"
      sql = prepare_run(sentinel_query)
      conn.exec("UPDATE public.orders SET status = '#{sentinel}' WHERE id % 10 <> 0")
      conn.exec("ANALYZE public.orders")

      error = refusal(sql)
      expect(error&.rule).to eq("plan_gate_mismatch_likely_stale_statistics")
      expect(leaks?(error)).to be(false)
    end

    it "has a leak check that catches a sentinel planted in an Error" do
      expect(leaks?(described_class::Error.new("plan_gate_bad_plan", "near #{sentinel}"))).to be(true)
    end

    def leaks?(error) = [error.rule, error.message, error.inspect, error.cause.inspect].join.include?("SENTINEL")
  end
end
