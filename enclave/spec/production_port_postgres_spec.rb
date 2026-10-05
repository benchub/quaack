# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"
require_relative "../../spec/support/test_pg_dump"

# `quaacks intake --port` (task 20261004-18): production listens on a port
# libpq's setup doesn't name, and every step that reaches production,
# schema-dump's pg_dump included, connects there anyway. Each runs the way
# the jump server runs it: the installed quaacks in its own process,
# outside Bundler, with the operator's libpq setup in a temporary HOME.
# PGPORT is wrong, so the run's port is the only way in. The harness's
# Postgres is published on a port Docker picks, never 5432.
RSpec.describe "quaacks with production's port from intake --port, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:inputs) { File.join(quaacks.home, "inputs").tap { FileUtils.mkdir_p(it) } }
  let(:query) { "SELECT i.id FROM sales.items i JOIN public.orders o ON o.id = i.order_id WHERE o.id = 1" }
  # The steps of setup that read production, in their order.
  let(:production_steps) { %w[inventory qualify volatility statistics schema-dump] }

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE public.orders (id int PRIMARY KEY);
      CREATE TABLE sales.items (id int, order_id int REFERENCES public.orders);
      INSERT INTO public.orders SELECT generate_series(1, 100);
      ANALYZE;
    SQL
    File.write(File.join(inputs, "plan.json"),
               conn.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{query}").getvalue(0, 0))
    conn.close
    File.write(File.join(inputs, "query.sql"), query)
    pgpass = File.join(quaacks.home, ".pgpass")
    File.write(pgpass, "*:#{production.port}:*:#{production.user}:#{production.password}\n")
    File.chmod(0o600, pgpass)
  end

  after do
    quaacks.remove
    production.drop
  end

  # Only these libpq variables, and a pg_dump of the server's major
  # version first on PATH.
  def operator_env(**vars)
    ENV.keys.grep(/\APG/).to_h { [it, nil] }
       .merge("PGUSER" => production.user, "PGDATABASE" => production.name,
              "PATH" => "#{TestPgDump.bin}:#{ENV.fetch("PATH")}", **vars.transform_keys(&:to_s))
  end

  def intake_args = ["--query", File.join(inputs, "query.sql"), "--plan", File.join(inputs, "plan.json")]

  def intake(*extra, env:)
    outcome = quaacks.run("intake", *intake_args, "--server", production.host, *extra, env:)
    expect(outcome.status).to be_success, outcome.stdout
    JSON.parse(outcome.stdout.lines.first).fetch("run_id")
  end

  def step(name, run_id, env:) = quaacks.run(name, "--run", run_id, env:)

  def last_line(outcome) = JSON.parse(outcome.stdout.lines.last)

  def expect_done(outcome, name)
    expect([outcome.status.exitstatus, last_line(outcome)])
      .to eq([0, { "type" => "done" }]), "#{name}: #{outcome.stdout}"
  end

  def stored(run_id) = Quaack::Enclave::Store.open(run_id, base: quaacks.store_base)

  it "reaches production on the run's port in every step, over a wrong PGPORT" do
    expect(production.port).not_to eq(5432)
    env = operator_env(PGPORT: "1")
    run_id = intake("--port", production.port.to_s, env:)

    production_steps.each do |name|
      expect_done(step(name, run_id, env:), name)
    end
    expect(stored(run_id).read("inventory")["major_version"]).to eq(18)
    expect(stored(run_id).read("schema_subset")["ddl"]).to include("CREATE TABLE sales.items (")
  end

  it "gives pg_dump the run's port too, so schema-dump reaches production over a wrong PGPORT" do
    good = operator_env(PGPORT: production.port.to_s)
    run_id = intake("--port", production.port.to_s, env: good)
    expect_done(step("qualify", run_id, env: good), "qualify")

    expect_done(step("schema-dump", run_id, env: operator_env(PGPORT: "1")), "schema-dump")
    expect(stored(run_id).read("schema_dump")["ddl"]).to include("CREATE TABLE public.orders (")
  end

  it "leaves the port to libpq's setup without --port, as before" do
    run_id = intake(env: operator_env(PGPORT: production.port.to_s))
    expect(stored(run_id).entry?("production_port")).to be(false)

    production_steps.each do |name|
      expect_done(step(name, run_id, env: operator_env(PGPORT: production.port.to_s)), name)
    end

    outcome = step("inventory", run_id, env: operator_env(PGPORT: "1"))
    expect(last_line(outcome)).to eq("type" => "error", "step" => "inventory", "rule" => "production_connection_failed")
  end
end
