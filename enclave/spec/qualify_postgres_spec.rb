# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks qualify --run <run ID>` (DESIGN.md, steps 1 and 3a) the way the jump
# server runs it: the installed quaacks in its own process, outside Bundler,
# connecting to the run's production server with the operator's libpq setup
# in a temporary HOME, as `quaacks inventory` does. The production server is
# a stand-in database (see ProductionServer). The query holds a sentinel
# literal, and the plan's search_path names a schema that isn't public.
RSpec.describe "quaacks qualify, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) { "SELECT o.id FROM orders o JOIN items USING (id) WHERE o.note = '#{sentinels.text}'" }
  let(:plan_settings) { { "search_path" => "sales, public" } }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("query", query)
      store.write("plan", [{ "Plan" => { "Node Type" => "Result" }, "Settings" => plan_settings }])
    end
  end

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.orders (id int, note text);
      CREATE TABLE public.orders (id int, note text);
      CREATE TABLE public.items (id int);
      CREATE VIEW sales.order_view AS SELECT * FROM sales.orders;
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

  def qualify(env: operator_env) = quaacks.run("qualify", "--run", store.run_id, env: libpq_env(**env))

  def done = %({"type":"done"}\n)
  def error_line(rule) = %({"type":"error","step":"qualify","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(%w[qualified_query relations].select { stored.entry?(it) }).to eq([])
    expect_no_leaks(sentinels, outcome)
  end

  it "stores the qualified query and its relations, resolved through the plan's search_path, and prints only DONE" do
    pgpass

    outcome = qualify

    expect(outcome.stdout).to eq(done)
    expect(outcome.stderr).to eq("")
    expect(outcome.status.exitstatus).to eq(0)
    expect(stored.read("qualified_query"))
      .to eq("SELECT o.id FROM sales.orders o JOIN public.items USING (id) WHERE o.note = '#{sentinels.text}'")
    expect(stored.read("relations")).to eq([{ "schema" => "sales", "name" => "orders" },
                                            { "schema" => "public", "name" => "items" }])
    expect_no_leaks(sentinels, outcome)
  end

  context "with a CTE, a subquery, a quoted name, and an already-qualified one" do
    let(:query) do
      <<~SQL.chomp
        WITH recent AS (SELECT id FROM "Mixed Case" WHERE note = '#{sentinels.text}')
        SELECT r.id FROM recent r WHERE r.id IN (SELECT id FROM items) AND EXISTS (SELECT FROM public.orders)
      SQL
    end

    it "qualifies the tables and leaves the CTE's name alone" do
      pgpass
      conn = production.connect
      conn.exec(%(CREATE TABLE sales."Mixed Case" (id int, note text)))
      conn.close

      expect(qualify.stdout).to eq(done)
      expect(stored.read("qualified_query")).to eq(<<~SQL.chomp.tr("\n", " "))
        WITH recent AS (SELECT id FROM sales."Mixed Case" WHERE note = '#{sentinels.text}')
        SELECT r.id FROM recent r WHERE r.id IN (SELECT id FROM public.items) AND EXISTS (SELECT FROM public.orders)
      SQL
      expect(stored.read("relations")).to eq([{ "schema" => "sales", "name" => "Mixed Case" },
                                              { "schema" => "public", "name" => "items" },
                                              { "schema" => "public", "name" => "orders" }])
    end
  end

  context "without a search_path in the plan's SETTINGS" do
    let(:plan_settings) { {} }

    # The stand-in's own search_path starts with a sentinel schema, which
    # has an orders table too. The session's path would find that one, and
    # the default path, "$user", public, finds public.orders.
    it "uses the default search path, not the session's" do
      pgpass
      conn = production.connect
      conn.exec(%(CREATE SCHEMA "#{sentinels.text}"; CREATE TABLE "#{sentinels.text}".orders (id int, note text)))
      conn.close

      expect(qualify.stdout).to eq(done)
      expect(stored.read("relations").first).to eq("schema" => "public", "name" => "orders")
    end
  end

  context "with a view" do
    let(:query) { "SELECT id FROM order_view WHERE note = '#{sentinels.text}'" }

    it "refuses it as view_relation, and stores nothing" do
      pgpass

      expect_failed(qualify, "view_relation")
    end
  end

  context "with a relation no schema has" do
    let(:query) { "SELECT id FROM nowhere WHERE note = '#{sentinels.text}'" }

    it "refuses it as unknown_relation" do
      pgpass

      expect_failed(qualify, "unknown_relation")
    end
  end

  context "with an unsupported construct" do
    let(:query) { "SELECT id FROM orders TABLESAMPLE SYSTEM (1) WHERE note = '#{sentinels.text}'" }

    it "refuses it as unsupported_construct" do
      pgpass

      expect_failed(qualify, "unsupported_construct")
    end
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    pgpass(user: sentinels.word, password: sentinels.text)

    outcome = qualify(env: operator_env(PGUSER: sentinels.word))

    expect_failed(outcome, "production_connection_failed")
    expect(outcome.stdout).not_to include(production.host)
  end
end
