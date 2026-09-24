# frozen_string_literal: true

require "json"
require "quaack/enclave/relation_qualifier"

# Every example runs against real Postgres, since resolving a name means
# reading the production catalog. Each one gets a fresh copy of the sample
# schema, whose tables live in public.
RSpec.describe Quaack::Enclave::RelationQualifier do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  def qualify(sql, settings = nil, connection: conn) = described_class.qualify(sql, settings, connection)

  def deparse(sql) = PgQuery.parse(sql).deparse

  # The Settings hash from a real EXPLAIN (SETTINGS, FORMAT JSON), run with
  # search_path set to path. Only the test's own session changes its path.
  def settings_for(path)
    conn.exec("SET search_path = #{path}")
    plan = conn.exec("EXPLAIN (SETTINGS, FORMAT JSON) SELECT 1").getvalue(0, 0)
    JSON.parse(plan).dig(0, "Settings")
  ensure
    conn.exec("RESET search_path")
  end

  # A widgets table in each schema, holding one row that names the schema,
  # so a query shows which one it read.
  def widgets_in(*schemas)
    schemas.each do |schema|
      quoted = conn.quote_ident(schema)
      conn.exec("CREATE SCHEMA IF NOT EXISTS #{quoted}")
      conn.exec("CREATE TABLE #{quoted}.widgets (home text)")
      conn.exec_params("INSERT INTO #{quoted}.widgets VALUES ($1)", [schema])
    end
  end

  describe "a query that already qualifies every relation" do
    it "comes back unchanged, with nothing resolved" do
      sql = "SELECT o.id FROM public.orders o JOIN public.customers c ON c.id = o.customer_id"

      result = qualify(sql)

      expect(result.sql).to eq(deparse(sql))
      expect(result.resolved).to eq({})
    end

    it "keeps the schema it names, even when the search path would pick another" do
      widgets_in("a", "b")

      result = qualify("SELECT home FROM a.widgets", settings_for("b, a"))

      expect(result.sql).to eq(deparse("SELECT home FROM a.widgets"))
    end
  end

  describe "the search path from the plan's SETTINGS" do
    it "picks the first schema in the path that has the relation" do
      widgets_in("a", "b")

      expect(qualify("SELECT home FROM widgets", settings_for("b, a")).sql).to eq(deparse("SELECT home FROM b.widgets"))
      expect(qualify("SELECT home FROM widgets", settings_for("a, b")).sql).to eq(deparse("SELECT home FROM a.widgets"))
    end

    it "returns each resolved name with the table it resolved to" do
      widgets_in("a", "b")

      sql = "SELECT * FROM widgets JOIN orders ON true JOIN widgets w2 ON true"

      result = qualify(sql, settings_for("b, a, public"))

      expect(result.resolved).to eq("widgets" => table_name("b", "widgets"), "orders" => table_name("public", "orders"))
    end

    it "gives a query that reads the same rows under any search path" do
      widgets_in("a", "b")
      qualified = qualify("SELECT home FROM widgets", settings_for("b, a")).sql

      conn.exec("SET search_path = a")
      expect(conn.exec(qualified).column_values(0)).to eq(["b"])
    ensure
      conn.exec("RESET search_path")
    end

    it "skips a schema in the path that doesn't exist" do
      widgets_in("a")

      expect(qualify("SELECT home FROM widgets", settings_for("nosuch, a")).sql)
        .to eq(deparse("SELECT home FROM a.widgets"))
    end

    it "skips a schema whose relations don't include the name" do
      widgets_in("b")
      conn.exec("CREATE SCHEMA a")

      expect(qualify("SELECT home FROM widgets", settings_for("a, b")).sql).to eq(deparse("SELECT home FROM b.widgets"))
    end

    it "searches pg_catalog first when the path doesn't list it" do
      conn.exec("CREATE TABLE public.pg_class (home text)")

      expect(qualify("SELECT * FROM pg_class", settings_for("public")).sql)
        .to eq(deparse("SELECT * FROM pg_catalog.pg_class"))
    end

    it "searches pg_catalog where the path lists it" do
      conn.exec("CREATE TABLE public.pg_class (home text)")

      expect(qualify("SELECT * FROM pg_class", settings_for("public, pg_catalog")).sql)
        .to eq(deparse("SELECT * FROM public.pg_class"))
    end

    it "searches only pg_catalog under an empty path" do
      settings = settings_for("''")

      expect(settings).to eq("search_path" => '""')
      expect(qualify("SELECT * FROM pg_class", settings).sql).to eq(deparse("SELECT * FROM pg_catalog.pg_class"))
      expect { qualify("SELECT * FROM orders", settings) }.to raise_error(described_class::Error, /orders/)
    end

    it "folds unquoted path entries to lower case and keeps quoted ones as written" do
      widgets_in("b", "Mixed Case")

      # Postgres already folds the entries it writes, so this one is written
      # by hand.
      expect(qualify("SELECT home FROM widgets", { "search_path" => "B" }).sql)
        .to eq(deparse("SELECT home FROM b.widgets"))
      expect(qualify("SELECT home FROM widgets", settings_for('"Mixed Case", b')).sql)
        .to eq(deparse('SELECT home FROM "Mixed Case".widgets'))
    end

    it "reads a doubled quote inside a quoted path entry as one quote" do
      widgets_in('a"b', "b")

      expect(qualify("SELECT home FROM widgets", settings_for('"a""b", b')).sql)
        .to eq(deparse('SELECT home FROM "a""b".widgets'))
    end

    it "matches a quoted, mixed-case relation name exactly" do
      conn.exec('CREATE SCHEMA "Sales"')
      conn.exec('CREATE TABLE "Sales"."Order Items" (id int)')
      conn.exec("CREATE TABLE \"Sales\".\"order items\" (id int)")

      expect(qualify('SELECT * FROM "Order Items"', settings_for('"Sales"')).sql)
        .to eq(deparse('SELECT * FROM "Sales"."Order Items"'))
    end

    it "folds an unquoted relation name to lower case" do
      widgets_in("a")

      expect(qualify("SELECT home FROM WIDGETS", settings_for("a")).sql).to eq(deparse("SELECT home FROM a.widgets"))
    end

    it "raises on a path it can't read, without guessing" do
      expect { qualify("SELECT * FROM orders", { "search_path" => '"public' }) }
        .to raise_error(described_class::Error, /search_path/)
      expect { qualify("SELECT * FROM orders", { "search_path" => "a,,public" }) }
        .to raise_error(described_class::Error, /search_path/)
    end
  end

  describe "$user in the path" do
    # The harness connects as postgres, so a schema named postgres is the
    # $user schema.
    it "stands for the connecting role, quoted or not" do
      widgets_in("postgres", "public")

      expect(qualify("SELECT home FROM widgets", settings_for('"$user", public')).sql)
        .to eq(deparse("SELECT home FROM postgres.widgets"))
      expect(qualify("SELECT home FROM widgets", { "search_path" => "$user, public" }).sql)
        .to eq(deparse("SELECT home FROM postgres.widgets"))
    end

    it "is skipped when the role has no schema of its own" do
      widgets_in("public")

      expect(qualify("SELECT home FROM widgets", { "search_path" => '"$user", public' }).sql)
        .to eq(deparse("SELECT home FROM public.widgets"))
    end
  end

  describe "a plan whose SETTINGS has no search_path" do
    it "uses the default, \"$user\" then public" do
      widgets_in("postgres", "public")

      expect(settings_for("DEFAULT")).to eq({})
      expect(qualify("SELECT home FROM widgets", {}).sql).to eq(deparse("SELECT home FROM postgres.widgets"))
      expect(qualify("SELECT home FROM widgets", nil).sql).to eq(deparse("SELECT home FROM postgres.widgets"))
    end

    it "falls back to public when there's no $user schema" do
      expect(qualify("SELECT id FROM orders", nil).sql).to eq(deparse("SELECT id FROM public.orders"))
    end
  end

  describe "a schema the connecting role can't use" do
    let(:role) { "quaack_rq_#{Process.pid}" }

    after do
      @role_conn&.close
      conn.exec("DROP ROLE IF EXISTS #{role}")
    end

    it "is skipped, as Postgres skips it" do
      widgets_in("hidden", "public")
      conn.exec("CREATE ROLE #{role} LOGIN PASSWORD 'rq'")
      @role_conn = PG.connect(**test_database.connection_params, user: role, password: "rq")

      expect(qualify("SELECT home FROM widgets", settings_for("hidden, public"), connection: @role_conn).sql)
        .to eq(deparse("SELECT home FROM public.widgets"))
    end
  end

  describe "CTE names" do
    before { widgets_in("a") }

    let(:settings) { settings_for("a") }

    it "leaves a reference to a CTE alone, even one that shadows a table" do
      sql = "WITH widgets AS (SELECT 1 AS home) SELECT home FROM widgets"

      result = qualify(sql, settings)

      expect(result.sql).to eq(deparse(sql))
      expect(result.resolved).to eq({})
    end

    it "lets a CTE reach later CTEs in the same WITH, but not itself or earlier ones" do
      sql = "WITH first AS (SELECT home FROM widgets), widgets AS (SELECT home FROM first) " \
            "SELECT home FROM widgets"

      expect(qualify(sql, settings).sql).to eq(deparse(<<~SQL))
        WITH first AS (SELECT home FROM a.widgets), widgets AS (SELECT home FROM first)
        SELECT home FROM widgets
      SQL
    end

    it "treats a non-recursive CTE's own name inside its body as the table" do
      sql = "WITH widgets AS (SELECT home FROM widgets) SELECT home FROM widgets"

      expect(qualify(sql, settings).sql)
        .to eq(deparse("WITH widgets AS (SELECT home FROM a.widgets) SELECT home FROM widgets"))
    end

    it "lets a recursive CTE refer to itself" do
      sql = "WITH RECURSIVE widgets(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM widgets WHERE n < 3) " \
            "SELECT n FROM widgets"

      expect(qualify(sql, settings).sql).to eq(deparse(sql))
    end

    it "reaches subqueries under the WITH, but not queries outside it" do
      sql = "SELECT (SELECT count(*) FROM widgets) FROM " \
            "(WITH widgets AS (SELECT 1) SELECT * FROM (SELECT * FROM widgets) s) t"

      expect(qualify(sql, settings).sql).to eq(deparse(<<~SQL))
        SELECT (SELECT count(*) FROM a.widgets) FROM
        (WITH widgets AS (SELECT 1) SELECT * FROM (SELECT * FROM widgets) s) t
      SQL
    end

    it "reaches every branch of a set operation under the WITH" do
      sql = "WITH widgets AS (SELECT 1 AS home) SELECT home FROM widgets UNION SELECT home FROM widgets"

      expect(qualify(sql, settings).sql).to eq(deparse(sql))
    end

    it "still qualifies the relations inside a data-modifying CTE" do
      sql = "WITH gone AS (DELETE FROM widgets RETURNING home) SELECT home FROM gone"

      expect(qualify(sql, settings).sql)
        .to eq(deparse("WITH gone AS (DELETE FROM a.widgets RETURNING home) SELECT home FROM gone"))
    end
  end

  describe "aborting" do
    it "names the rule and the relation when a name resolves nowhere" do
      expect { qualify("SELECT * FROM nowhere_table", settings_for("public")) }
        .to raise_error(described_class::Error,
                        "relation nowhere_table isn't schema qualified, and no schema in the search path " \
                        "(pg_catalog, public) has it")
    end

    it "never puts the query's literals in the message" do
      sentinel = "QUAACK_SENTINEL_7f3a"
      errors = [
        "SELECT * FROM nowhere_table WHERE note = '#{sentinel}'",
        "SELECT '#{sentinel}' '#{sentinel}' FROM public.orders",
        "SELECT * FROM public.orders WHERE note = '#{sentinel}' AND"
      ].map do |sql|
        qualify(sql)
        nil
      rescue described_class::Error => e
        e
      end

      expect(errors).to all(be_a(described_class::Error))
      errors.each do |error|
        expect(error.message).not_to include(sentinel)
        expect(error.full_message).not_to include(sentinel)
      end
    end
  end
end
