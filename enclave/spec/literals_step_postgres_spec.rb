# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/redaction"
require "quaack/enclave/store"
require "quaack/enclave/table_name"
require_relative "support/production_server"

# `quaacks literals --run <run ID>` (DESIGN.md's literals) the way the jump server runs
# it: the installed quaacks in its own process, outside Bundler. Its inputs
# come from redact and statistics, run in-process against a real database whose values
# are sentinels. The step itself needs no production connection.
RSpec.describe "quaacks literals" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) { "SELECT o.id FROM public.orders o WHERE o.note = 'x' AND o.code = 5" }
  let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base).tap { prepare(it) } }

  after do
    quaacks.remove
    production.drop
  end

  # The sentinel fills most rows of note, so it tops the MCV list and
  # becomes the worst-case literal, a real value the step must never print.
  def seed(conn)
    conn.exec(<<~SQL)
      CREATE TABLE public.orders (id int, note text, code bigint);
      INSERT INTO public.orders SELECT i, CASE WHEN i % 4 = 0 THEN 'other' ELSE '#{sentinels.text}' END, i % 7
      FROM generate_series(1, 2000) AS i;
      ANALYZE public.orders;
    SQL
  end

  def prepare(store)
    conn = production.connect
    seed(conn)
    redact_into(store, conn)
    relations = [Quaack::Enclave::TableName.new(schema: "public", name: "orders")]
    Quaack::Enclave::PlannerStatistics.run(store:, relations:, connection: conn)
    store.write("volatility", { "passed" => true })
  ensure
    conn&.close
  end

  def redact_into(store, conn)
    explain = JSON.parse(conn.exec("EXPLAIN (ANALYZE, FORMAT JSON) #{query}").getvalue(0, 0))
    redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(query), explain)
    redacted.store(store)
    store.write("redacted_query", redacted.query.sql)
  end

  def no_libpq_env = ENV.keys.grep(/\APG/).to_h { [it, nil] }
  def literals(run_id = store.run_id) = quaacks.run("literals", "--run", run_id, env: no_libpq_env)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def drop_entry(name) = File.delete(File.join(store.path, "#{name}.json"))

  it "stores the literal sets, printing only DONE" do
    outcome = literals

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    sets = stored.read("literal_sets")
    expect(sets.keys.sort).to eq(%w[fallbacks slow typical worst_case])
    expect(sets["slow"].transform_values { it["value"] }).to eq("$1" => "x", "$2" => "5")
    expect(sets["worst_case"]["$1"]["value"]).to eq(sentinels.text)
    expect_no_leaks(sentinels, outcome)
  end

  it "keeps the sentinel in the store, where the leak check would catch it" do
    literals

    held = JSON.generate(stored.read("literal_sets"))
    expect(LeakCheck.findings(sentinels, stdout: held).join("\n")).to include(sentinels.needles[:text])
  end

  it "refuses a run whose query hasn't passed the volatility check, storing nothing" do
    drop_entry("volatility")

    outcome = literals

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"literals","rule":"volatility_not_passed"}\n), "", 70])
    expect(stored.entry?("literal_sets")).to be(false)
  end

  it "refuses a run whose volatility entry is there but didn't pass, storing nothing" do
    store.write("volatility", { "passed" => false })

    outcome = literals

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"literals","rule":"volatility_not_passed"}\n), "", 70])
    expect(stored.entry?("literal_sets")).to be(false)
  end

  # 20261004-92: later steps compare measurements made in separate processes by set name, so the
  # sets mustn't change once one has measured with them.
  it "can run again while no later step has measured with the sets, storing the same sets" do
    literals
    first = stored.read("literal_sets")

    expect(literals.status.exitstatus).to eq(0)
    expect(stored.read("literal_sets")).to eq(first)
  end

  %w[baseline index_baseline candidate_runs result_comparison index_search_original
     index_search_rewrite_2].each do |entry|
    it "refuses to run again once #{entry} exists, leaving the stored sets alone" do
      literals
      first = stored.read("literal_sets")
      stored.write(entry, {})

      outcome = literals

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([%({"type":"error","step":"literals","rule":"literals_already_used"}\n), "", 70])
      expect(stored.read("literal_sets")).to eq(first)
    end
  end

  it "refuses a run with no statistics entry as missing_statistics, storing nothing" do
    drop_entry("statistics")

    outcome = literals

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"literals","rule":"missing_statistics"}\n), "", 70])
    expect(stored.entry?("literal_sets")).to be(false)
  end
end
