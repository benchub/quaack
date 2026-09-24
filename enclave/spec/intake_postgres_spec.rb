# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"

# `quaacks intake` the way the operator runs it on the jump server: the
# installed quaacks in its own process, outside Bundler, with the query in
# one file and the EXPLAIN output in another, captured from the test
# harness's Postgres just now. HOME is a temporary directory, so the runs
# land under it, never in the real ~/.quaack.
RSpec.describe "quaacks intake, from a real EXPLAIN" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { LeakCheck::Sentinels.new }
  # Where the operator keeps the input files. Its name holds a sentinel, so
  # a path that got echoed would show.
  let(:inputs) { File.join(quaacks.home, "#{sentinels.word}-inputs").tap { Dir.mkdir(it) } }
  let(:runs_base) { quaacks.store_base }
  # Literals that stand in for production values.
  let(:query) do
    "SELECT c.id, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
      "WHERE c.email = '#{sentinels.text}' OR c.name LIKE '#{sentinels.like}' OR o.total_cents = #{sentinels.number} " \
      "ORDER BY o.total_cents"
  end

  after { quaacks.remove }

  def explain(how, settings: [])
    conn = test_database.connection
    conn.transaction do
      settings.each { |s| conn.exec("SET LOCAL #{s}") }
      conn.exec("#{how} #{query}").column_values(0).join("\n")
    end
  end

  def input(name, text) = File.join(inputs, name).tap { File.write(it, text) }

  def quaacks_intake(plan_text, *extra)
    quaacks.run("intake", "--query", input("query.sql", query), "--plan", input("plan.json", plan_text),
                "--server", "prod-db-3", *extra)
  end

  def runs = quaacks.runs

  # The plan the step reads holds the sentinels, so a clean output means
  # the step kept them in, not that it never saw them.
  def expect_exposed(plan_text)
    expect(LeakCheck.findings(sentinels, stdout: plan_text).map(&:sentinel)).to include(:text, :like, :number)
  end

  it "takes EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) and prints only the new run's ID" do
    plan_text = explain("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)", settings: ["enable_hashjoin = off"])
    expect_exposed(plan_text)

    outcome = quaacks_intake(plan_text, "--captured-at", "2026-09-23T15:15:00-07:00")

    expect(outcome.status.exitstatus).to eq(0), outcome.stdout
    expect(outcome.stderr).to eq("")
    expect(runs.size).to eq(1)
    expect(outcome.stdout).to eq(%({"type":"run","run_id":"#{runs[0]}"}\n{"type":"done"}\n))
    expect_no_leaks(sentinels, outcome)

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

    outcome = quaacks_intake(plan_text)

    expect(outcome.status.exitstatus).to eq(0), outcome.stdout
    expect(runs.size).to eq(1)
  end

  it "takes a plan from ANALYZE with TIMING OFF" do
    outcome = quaacks_intake(explain("EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SETTINGS, FORMAT JSON)"))

    expect(outcome.status.exitstatus).to eq(0), outcome.stdout
    expect(runs.size).to eq(1)
  end

  it "refuses a query it doesn't support without echoing it, and leaves no run" do
    plan_text = explain("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)")
    input("query.sql", "#{query} FOR UPDATE")
    outcome = quaacks.run("intake", "--query", File.join(inputs, "query.sql"),
                          "--plan", input("plan.json", plan_text), "--server", "prod-db-3")

    expect(outcome.stdout).to eq(%({"type":"error","step":"intake","rule":"unsupported_construct"}\n))
    expect(outcome.stderr).to eq("")
    expect(outcome.status.exitstatus).to eq(70)
    expect_no_leaks(sentinels, outcome)
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
      expect_exposed(plan_text)

      outcome = quaacks_intake(plan_text)

      expect(outcome.stdout).to eq(%({"type":"error","step":"intake","rule":"#{rule}"}\n))
      expect(outcome.stderr).to eq("")
      expect(outcome.status.exitstatus).to eq(70)
      expect_no_leaks(sentinels, outcome)
      expect(runs).to eq([])
    end
  end
end
