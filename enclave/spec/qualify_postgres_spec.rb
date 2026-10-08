# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"
require_relative "support/catalog_shadow"

# `quaacks qualify --run <run ID>` (DESIGN.md, input and qualify) the way the jump
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
  let(:plan) { [{ "Plan" => { "Node Type" => "Result" }, "Settings" => plan_settings }] }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("query", query)
      store.write("plan", plan)
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
    expect(%w[qualified_query relations search_path].select { stored.entry?(it) }).to eq([])
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

  # Task 20260926-56: for RunServer.connect, so later steps resolve a name
  # qualify leaves bare the same way.
  it "stores the search path it resolved names through, as the plan wrote it" do
    pgpass
    expect(qualify.stdout).to eq(done)
    expect(stored.read("search_path")).to eq(%w[sales public])
  end

  # Task 20261007-30: the stored path is the operator role's, so later
  # steps, which connect to the run server as another role, search what
  # qualify did: "$user" is the operator's role, and a schema that role
  # may not use, which Postgres skips, is left out.
  context "when the operator's role isn't the run server's" do
    let(:role) { "operator_#{SecureRandom.hex(4)}" }
    let(:plan_settings) { { "search_path" => %("$user", locked, nowhere, public) } }

    before do
      production.server.admin.exec(%(CREATE ROLE "#{role}" LOGIN PASSWORD '#{production.password}'))
      conn = production.connect
      conn.exec("CREATE SCHEMA locked")
      conn.close
      pgpass(user: role)
    end

    after { production.server.admin.exec(%(DROP ROLE IF EXISTS "#{role}")) }

    it "stores the path with \"$user\" as the operator's role" do
      expect(qualify(env: operator_env(PGUSER: role)).stdout).to eq(done)
      expect(stored.read("search_path").first).to eq(role)
    end

    it "leaves out a schema the operator's role may not use, and keeps one that isn't there" do
      expect(qualify(env: operator_env(PGUSER: role)).stdout).to eq(done)
      expect(stored.read("search_path")).to eq([role, "nowhere", "public"])
    end
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

  # Task 20260924-3: every table the plan scans must be one the query
  # reads, or an inheritance descendant of one. A query table the plan
  # doesn't scan is fine, since the planner can drop one.
  context "when the plan is a real EXPLAIN" do
    let(:explained) { query }
    let(:explain_options) { "ANALYZE, BUFFERS, SETTINGS, FORMAT JSON" }
    let(:plan) do
      conn = production.connect
      conn.exec("SET search_path = sales, public")
      JSON.parse(conn.exec("EXPLAIN (#{explain_options}) #{explained}").getvalue(0, 0))
    ensure
      conn&.close
    end

    before do
      conn = production.connect
      conn.exec(<<~SQL)
        CREATE TABLE public.customers (id int PRIMARY KEY, name text);
        CREATE TABLE sales.child_orders () INHERITS (sales.orders);
      SQL
      conn.close
      pgpass
    end

    it "takes the query's own plan" do
      expect(plan.to_json).to include(%("Relation Name":"items"))
      expect(qualify.stdout).to eq(done)
    end

    it "takes a plan that scans a query table's inheritance child" do
      expect(plan.to_json).to include(%("Relation Name":"child_orders"))
      expect(qualify.stdout).to eq(done)
    end

    context "with a join the planner removed" do
      let(:query) do
        "SELECT o.id FROM orders o LEFT JOIN customers c ON c.id = o.id WHERE o.note = '#{sentinels.text}'"
      end

      it "takes the plan, which doesn't scan the removed table" do
        expect(plan.to_json).not_to include(%("Relation Name":"customers"))
        expect(qualify.stdout).to eq(done)
      end
    end

    context "with a filter the planner proved false" do
      let(:query) { "SELECT o.id FROM orders o JOIN items USING (id) WHERE false AND o.note = '#{sentinels.text}'" }

      it "takes the plan, which scans no table at all" do
        expect(plan.to_json).not_to include("Relation Name")
        expect(qualify.stdout).to eq(done)
      end
    end

    context "with another query's plan" do
      let(:explained) { "SELECT c.id FROM customers c JOIN orders o USING (id) WHERE c.name = '#{sentinels.text}'" }

      it "refuses it as plan_table_mismatch, and stores nothing" do
        expect(plan.to_json).to include(%("Relation Name":"customers"))
        expect_failed(qualify, "plan_table_mismatch")
      end
    end

    context "with ONLY, and a plan that scans the inheritance child" do
      let(:query) { "SELECT o.id FROM ONLY orders o WHERE o.note = '#{sentinels.text}'" }
      let(:explained) { "SELECT o.id FROM orders o WHERE o.note = '#{sentinels.text}'" }

      it "refuses it as plan_table_mismatch" do
        expect(plan.to_json).to include(%("Relation Name":"child_orders"))
        expect_failed(qualify, "plan_table_mismatch")
      end
    end

    context "with a VERBOSE plan of a table of the same name in another schema" do
      let(:explain_options) { "ANALYZE, VERBOSE, BUFFERS, SETTINGS, FORMAT JSON" }
      let(:query) { "SELECT o.id FROM orders o WHERE o.note = '#{sentinels.text}'" }
      let(:explained) { "SELECT o.id FROM public.orders o WHERE o.note = '#{sentinels.text}'" }

      it "refuses it as plan_table_mismatch, by the plan's Schema" do
        expect(plan.to_json).to include(%("Schema":"public"))
        expect_failed(qualify, "plan_table_mismatch")
      end

      context "when the plan is the query's own" do
        let(:explained) { query }

        it "takes it" do
          expect(plan.to_json).to include(%("Schema":"sales"))
          expect(qualify.stdout).to eq(done)
        end
      end
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

  context "with the default search path, and a schema named for a role other than the operator's" do
    let(:plan_settings) { {} }
    let(:role) { "app_#{SecureRandom.hex(4)}" }

    after { production.server.admin.exec(%(DROP ROLE IF EXISTS "#{role}")) }

    def other_role_schema(ddl)
      production.server.admin.exec(%(CREATE ROLE "#{role}"))
      conn = production.connect
      conn.exec(%(CREATE SCHEMA "#{role}"; #{ddl}))
      conn.close
    end

    it "refuses it as ambiguous_user_schema when that schema has a table the query names, and stores nothing" do
      pgpass
      other_role_schema(%(CREATE TABLE "#{role}".orders (id int, note text)))

      expect_failed(qualify, "ambiguous_user_schema")
    end

    it "qualifies the query when that schema has only what the query doesn't name, as a monitoring tool's does" do
      pgpass
      other_role_schema(<<~SQL)
        CREATE FUNCTION "#{role}".explain_statement(l_query text, OUT explain json) RETURNS SETOF json
          LANGUAGE plpgsql AS 'BEGIN RETURN; END';
      SQL

      expect(qualify.stdout).to eq(done)
      expect(stored.read("relations")).to eq([{ "schema" => "public", "name" => "orders" },
                                              { "schema" => "public", "name" => "items" }])
    end
  end

  # Task 20260930-14: the session's search_path puts public ahead of
  # pg_catalog, and public holds comparisons that say no (see
  # CatalogShadow). Every read still names pg_catalog's, so it finds what
  # it did without them.
  context "when public's comparison operators shadow pg_catalog's" do
    let(:role) { "app_#{SecureRandom.hex(4)}" }

    after { production.server.admin.exec(%(DROP ROLE IF EXISTS "#{role}")) }

    def shadow(ddl = "")
      production.server.admin.exec(%(ALTER DATABASE "#{production.name}" SET search_path = public, pg_catalog))
      conn = production.connect
      conn.exec(ddl) unless ddl.empty?
      CatalogShadow.plant(conn, :operators)
      conn.close
    end

    it "resolves the query's relations through the plan's search_path as before" do
      pgpass
      shadow

      expect(qualify.stdout).to eq(done)
      expect(stored.read("relations")).to eq([{ "schema" => "sales", "name" => "orders" },
                                              { "schema" => "public", "name" => "items" }])
    end

    context "with the default search path" do
      let(:plan_settings) { {} }

      it "still refuses a query a role's schema could change as ambiguous_user_schema" do
        pgpass
        production.server.admin.exec(%(CREATE ROLE "#{role}"))
        shadow(%(CREATE SCHEMA "#{role}"; CREATE TABLE "#{role}".orders (id int, note text)))

        expect_failed(qualify, "ambiguous_user_schema")
      end
    end
  end

  # An operator role that can't read part of the catalog. The read fails
  # inside Production.read_only, which names it production_read_failed,
  # with its SQLSTATE, as the other production steps do.
  context "when the operator's role can't read a catalog the check needs" do
    let(:role) { "operator_#{SecureRandom.hex(4)}" }

    after { production.server.admin.exec(%(DROP ROLE IF EXISTS "#{role}")) }

    it "fails as production_read_failed, and stores nothing" do
      production.server.admin.exec(%(CREATE ROLE "#{role}" LOGIN PASSWORD '#{production.password}'))
      conn = production.connect
      conn.exec("REVOKE SELECT ON pg_catalog.pg_inherits FROM PUBLIC")
      conn.close
      pgpass(user: role)

      outcome = qualify(env: operator_env(PGUSER: role))

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([%({"type":"error","step":"qualify","rule":"production_read_failed","sqlstate":"42501"}\n), "", 70])
      expect(%w[qualified_query relations search_path].select { stored.entry?(it) }).to eq([])
      expect_no_leaks(sentinels, outcome)
    end
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    pgpass(user: sentinels.word, password: sentinels.text)

    outcome = qualify(env: operator_env(PGUSER: sentinels.word))

    expect_failed(outcome, "production_connection_failed")
    expect(outcome.stdout).not_to include(production.host)
  end
end
