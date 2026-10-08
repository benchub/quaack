# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"
require_relative "../../spec/support/test_pg_dump"

# `quaacks intake --database` (task 20261008-51): the operator's PGDATABASE
# lives in a login profile a non-interactive ssh session doesn't load, so
# libpq's setup names no database, or the wrong one. Every step that reaches
# production, schema-dump's pg_dump included, connects to the run's database
# anyway. Each runs the way the jump server runs it: the installed quaacks
# in its own process, outside Bundler, with only the libpq variables given.
RSpec.describe "quaacks with production's database from intake --database, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:inputs) { File.join(quaacks.home, "inputs").tap { FileUtils.mkdir_p(it) } }
  let(:query) { "SELECT i.id FROM sales.items i JOIN public.orders o ON o.id = i.order_id WHERE o.id = 1" }
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

  # Only these libpq variables, PGDATABASE unset unless given, and a
  # pg_dump of the server's major version first on PATH.
  def operator_env(**vars)
    ENV.keys.grep(/\APG/).to_h { [it, nil] }
       .merge("PGUSER" => production.user, "PGPORT" => production.port.to_s,
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
  def stored(run_id) = Quaack::Enclave::Store.open(run_id, base: quaacks.store_base)

  it "reaches the run's database in every step, pg_dump's included, with PGDATABASE unset" do
    env = operator_env
    run_id = intake("--database", production.name, env:)
    expect(stored(run_id).read("production_database")).to eq(production.name)

    production_steps.each do |name|
      outcome = step(name, run_id, env:)
      expect([outcome.status.exitstatus, last_line(outcome)]).to eq([0, { "type" => "done" }]),
                                                                 "#{name}: #{outcome.stdout}"
    end
    expect(stored(run_id).read("schema_subset")["ddl"]).to include("CREATE TABLE sales.items (")
    expect(stored(run_id).read("schema_dump")["ddl"]).to include("CREATE TABLE public.orders (")
  end

  it "leaves the database to libpq's setup without --database, as before" do
    env = operator_env(PGDATABASE: "no_such_database")
    run_id = intake(env:)
    expect(stored(run_id).entry?("production_database")).to be(false)

    outcome = step("inventory", run_id, env:)
    expect(last_line(outcome)).to eq("type" => "error", "step" => "inventory", "rule" => "production_connection_failed")
  end
end
