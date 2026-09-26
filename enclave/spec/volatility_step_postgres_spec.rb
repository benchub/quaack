# frozen_string_literal: true

require "securerandom"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks volatility --run <run ID>` (README 3d) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler, with
# the operator's libpq setup in a temporary HOME, as `quaacks qualify` does.
# It reads the run's server, plan, and qualified_query entries. The query
# holds a sentinel literal, and a volatile function lives in a schema only
# the plan's search_path names.
RSpec.describe "quaacks volatility, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) { "SELECT o.id, lower(o.note) FROM sales.orders o WHERE o.note = '#{sentinels.text}'" }
  let(:plan_settings) { { "search_path" => "sales, public" } }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("qualified_query", query)
      store.write("plan", [{ "Plan" => { "Node Type" => "Result" }, "Settings" => plan_settings }])
    end
  end

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.orders (id int, note text);
      CREATE FUNCTION sales.bump(int) RETURNS int VOLATILE LANGUAGE sql AS 'SELECT $1 + 1';
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

  def volatility(env: operator_env) = quaacks.run("volatility", "--run", store.run_id, env: libpq_env(**env))

  def done = %({"type":"done"}\n)

  def error_line(rule, sqlstate = nil)
    %({"type":"error","step":"volatility","rule":"#{rule}"#{%(,"sqlstate":"#{sqlstate}") if sqlstate}}\n)
  end

  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def expect_failed(outcome, rule, sqlstate = nil)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule, sqlstate), "", 70])
    expect(stored.entry?("volatility")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  it "stores the passed marker for a query with no volatile function, printing only DONE" do
    pgpass

    outcome = volatility

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([done, "", 0])
    expect(stored.read("volatility")).to eq({ "passed" => true })
    expect_no_leaks(sentinels, outcome)
  end

  context "with a volatile function in the select list" do
    let(:query) { "SELECT random(), o.id FROM sales.orders o WHERE o.note = '#{sentinels.text}'" }

    it "refuses it as volatile_function and stores nothing" do
      pgpass

      expect_failed(volatility, "volatile_function")
    end
  end

  context "with a volatile function found only through the plan's search_path" do
    let(:query) { "SELECT o.id FROM sales.orders o WHERE bump(o.id) = 3 AND o.note = '#{sentinels.text}'" }

    it "refuses it as volatile_function and stores nothing" do
      pgpass

      expect_failed(volatility, "volatile_function")
    end

    context "without that schema in the search_path" do
      let(:plan_settings) { { "search_path" => "public" } }

      it "doesn't see it, and stores the passed marker" do
        pgpass

        expect(volatility.stdout).to eq(done)
        expect(stored.read("volatility")).to eq({ "passed" => true })
      end
    end
  end

  context "with a construct outside the supported SQL list" do
    let(:query) { "SELECT o.id FROM sales.orders o WHERE o.note = '#{sentinels.text}' FOR UPDATE" }

    it "refuses it as unsupported_construct and stores nothing" do
      pgpass

      expect_failed(volatility, "unsupported_construct")
    end
  end

  # A role that may connect but can't read pg_aggregate, which the check's
  # function lookup joins, so the read fails with permission denied.
  context "when the catalog read fails" do
    let(:reader) { "reader_#{SecureRandom.hex(6)}" }

    before do
      conn = production.connect
      conn.exec(<<~SQL)
        CREATE ROLE #{reader} LOGIN PASSWORD '#{production.password}';
        REVOKE SELECT ON pg_catalog.pg_aggregate FROM PUBLIC;
      SQL
      conn.close
    end

    after { production.server.admin.exec("DROP ROLE IF EXISTS #{reader}") }

    it "fails as production_read_failed and stores nothing" do
      pgpass(user: reader)

      expect_failed(volatility(env: operator_env(PGUSER: reader)), "production_read_failed", "42501")
    end
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    pgpass(user: sentinels.word, password: sentinels.text)

    outcome = volatility(env: operator_env(PGUSER: sentinels.word))

    expect_failed(outcome, "production_connection_failed")
    expect(outcome.stdout).not_to include(production.host)
  end
end
