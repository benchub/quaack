# frozen_string_literal: true

require "quaack/enclave/store"
require "quaack/enclave/planner_statistics"
require_relative "support/production_server"

# `quaacks statistics --run <run ID>` (README 3c) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler, with
# the operator's libpq setup in a temporary HOME, as `quaacks qualify` does.
# It reads the run's server and relations entries, which qualify wrote.
#
# An MCV value and a partial index's predicate hold sentinels, standing in
# for production values that must stay in the enclave.
RSpec.describe "quaacks statistics, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:relations) { [{ "schema" => "sales", "name" => "items" }, { "schema" => "public", "name" => "orders" }] }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("relations", relations)
    end
  end
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE public.orders (id int PRIMARY KEY, status text);
      INSERT INTO public.orders SELECT g, CASE WHEN g % 10 = 0 THEN 'other' ELSE '#{sentinels.text}' END
        FROM generate_series(1, 1000) g;
      CREATE INDEX orders_status_idx ON public.orders (id) WHERE status = '#{sentinels.text}';
      CREATE TABLE sales.items (id int, order_id int REFERENCES public.orders);
      CREATE TABLE sales.parent (id int);
      CREATE TABLE sales.child () INHERITS (sales.parent);
      ANALYZE;
    SQL
    conn.close
  end

  after do
    quaacks.remove
    production.drop
  end

  def pgpass(user: production.user, password: production.password)
    path = File.join(quaacks.home, ".pgpass")
    File.write(path, "*:#{production.port}:*:#{user}:#{password}\n")
    File.chmod(0o600, path)
  end

  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def operator_env(**overrides)
    { PGPORT: production.port.to_s, PGUSER: production.user, PGDATABASE: production.name, **overrides }
  end

  def statistics(env: operator_env) = quaacks.run("statistics", "--run", store.run_id, env: libpq_env(**env))

  def done = %({"type":"done"}\n)

  def error_line(rule, sqlstate = nil)
    %({"type":"error","step":"statistics","rule":"#{rule}"#{%(,"sqlstate":"#{sqlstate}") if sqlstate}}\n)
  end

  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def expect_failed(outcome, rule, sqlstate = nil)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule, sqlstate), "", 70])
    expect(stored.entry?("statistics")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  it "stores the statistics of the query's tables in relations order, printing only DONE" do
    pgpass

    outcome = statistics

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([done, "", 0])
    tables = stored.read("statistics")["tables"]
    expect(tables.map { [it["schema"], it["name"]] }).to eq([%w[sales items], %w[public orders]])
    expect(tables.last["reltuples"]).to eq(1000.0)
    expect(tables.last["columns"]["status"]["most_common_vals"]).to include(sentinels.text)
    expect(tables.last["indexes"].map { it["name"] }).to eq(%w[orders_pkey orders_status_idx])
    expect(tables.last["indexes"].last["definition"]).to include(sentinels.text)
    expect_no_leaks(sentinels, outcome)
  end

  it "stores an entry PlannerStatistics.load rebuilds for the generators and Dedupe" do
    pgpass
    statistics

    table = Quaack::Enclave::PlannerStatistics.load(stored).statistics.table(orders)

    expect(table.value_frequency("status", sentinels.text)).to be_within(0.001).of(0.9)
    expect(table.indexes["orders_status_idx"].sources.to_a).to eq([:existing])
  end

  context "with a relation that's gone since qualify" do
    let(:relations) { [{ "schema" => "sales", "name" => "items" }, { "schema" => "sales", "name" => "gone" }] }

    it "refuses it as unknown_relation and stores nothing" do
      pgpass

      expect_failed(statistics, "unknown_relation")
    end
  end

  context "with an inheritance parent" do
    let(:relations) { [{ "schema" => "public", "name" => "orders" }, { "schema" => "sales", "name" => "parent" }] }

    it "refuses it as inheritance_parent and stores nothing" do
      pgpass

      expect_failed(statistics, "inheritance_parent")
    end
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    pgpass(user: sentinels.word, password: sentinels.text)

    outcome = statistics(env: operator_env(PGUSER: sentinels.word))

    expect_failed(outcome, "production_connection_failed")
    expect(outcome.stdout).not_to include(production.host)
  end

  # A role that may connect but can't read pg_stats, so the read fails with
  # permission denied (README 3c: the refusal stores nothing).
  context "when the statistics read fails" do
    let(:reader) { "reader_#{SecureRandom.hex(6)}" }

    before do
      conn = production.connect
      conn.exec(<<~SQL)
        CREATE ROLE #{reader} LOGIN PASSWORD '#{production.password}';
        REVOKE SELECT ON pg_catalog.pg_stats FROM PUBLIC;
      SQL
      conn.close
    end

    # The container is shared per process, so put the grant back.
    after do
      conn = production.connect
      conn.exec("GRANT SELECT ON pg_catalog.pg_stats TO PUBLIC")
      conn.close
      production.server.admin.exec("DROP ROLE IF EXISTS #{reader}")
    end

    it "fails as production_read_failed and stores nothing" do
      pgpass(user: reader)

      expect_failed(statistics(env: operator_env(PGUSER: reader)), "production_read_failed", "42501")
    end
  end
end
