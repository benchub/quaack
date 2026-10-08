# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena"
require "quaack/enclave/arena_runner"
require "quaack/enclave/counterexamples"
require "quaack/enclave/denormalized_fixture"
require "quaack/enclave/scenarios"
require_relative "support/catalog_shadow"

# Task 20261007-31: the arena's catalog reads, when public's relations,
# functions, operators, and types sit ahead of pg_catalog's on the
# search_path, as an arena loaded from a production dump can have them (see
# CatalogShadow). The scenarios rewrite-test builds, the counterexamples it
# prepares, and what they load are the same as with nothing planted.
RSpec.describe "the arena's catalog reads with catalog names shadowed" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  # Comparisons that say no, for the types the arena reads compare beyond
  # CatalogShadow's: attnum against a number, and ordinalities.
  NO = [["=", "int2", "int2"], [">", "int2", "int4"], ["<=", "int8", "int2"], [">=", "int4", "int4"],
        ["!~", "text", "text"], ["!~~", "name", "text"]].freeze
  NO_NAMES = { "=" => "eq", ">" => "gt", "<=" => "le", ">=" => "ge", "!~" => "nre", "!~~" => "nlike" }.freeze

  # Functions that answer wrong, by name: no type, a CHECK that refuses
  # everything, no key, no default, and nothing valid.
  FUNCTIONS = [
    "public.format_type(pg_catalog.oid, pg_catalog.int4) RETURNS pg_catalog.text AS $$ SELECT 'shadow' $$",
    "public.pg_get_constraintdef(pg_catalog.oid) RETURNS pg_catalog.text AS $$ SELECT 'CHECK (false)' $$",
    "public.pg_get_indexdef(pg_catalog.oid, pg_catalog.int4, pg_catalog.bool) RETURNS pg_catalog.text " \
    "AS $$ SELECT 'shadow' $$",
    "public.pg_get_expr(pg_catalog.pg_node_tree, pg_catalog.oid) RETURNS pg_catalog.text AS $$ SELECT NULL $$",
    "public.pg_input_is_valid(pg_catalog.text, pg_catalog.text) RETURNS pg_catalog.bool AS $$ SELECT false $$",
    "public.array_to_json(pg_catalog.anyarray) RETURNS pg_catalog.json AS $$ SELECT '[]'::pg_catalog.json $$",
    "public.setval(pg_catalog.regclass, pg_catalog.int8) RETURNS pg_catalog.int8 AS $$ SELECT 0::pg_catalog.int8 $$"
  ].freeze

  # What a read gave, with pg_catalog's names bare: with public's ahead of
  # them, pg_catalog's own deparsers (format_type, pg_get_expr, and the
  # like) print the names they'd otherwise leave bare with their schema,
  # so they still mean the same, and the reads take them as they are.
  def bare(found)
    found.inspect.gsub(/0x\h+/, "").gsub(/OPERATOR\(pg_catalog\.(\S+?)\)/, '\1').gsub("pg_catalog.", "").gsub("#<data", "\n#<data")
  end

  def plant
    CatalogShadow.plant(conn, :operators, :count, :to_regclass, :text)
    NO.each do |op, left, right|
      fn = "public.quaack_no_#{NO_NAMES.fetch(op)}_#{left}_#{right}"
      conn.exec("CREATE FUNCTION #{fn}(pg_catalog.#{left}, pg_catalog.#{right}) RETURNS pg_catalog.bool " \
                "LANGUAGE sql AS $$ SELECT false $$")
      conn.exec("CREATE OPERATOR public.#{op} (LEFTARG = pg_catalog.#{left}, RIGHTARG = pg_catalog.#{right}, " \
                "FUNCTION = #{fn})")
    end
    FUNCTIONS.each { conn.exec("CREATE FUNCTION #{it.sub(" AS ", " LANGUAGE sql AS ")}") }
    # Arithmetic that gives 0, for the steps either side of a number.
    conn.exec("CREATE FUNCTION public.quaack_zero(pg_catalog.int4, pg_catalog.int4) RETURNS pg_catalog.int4 " \
              "LANGUAGE sql AS $$ SELECT 0 $$")
    %w[+ -].each do |op|
      conn.exec("CREATE OPERATOR public.#{op} (LEFTARG = pg_catalog.int4, RIGHTARG = pg_catalog.int4, " \
                "FUNCTION = public.quaack_zero)")
    end
    conn.exec("CREATE DOMAIN public.regclass AS pg_catalog.regclass CHECK (false)")
    conn.exec("SET search_path = public, pg_catalog")
  end

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TYPE fx.mood AS ENUM ('sad', 'happy');
      CREATE DOMAIN fx.qty AS integer CHECK (VALUE >= 0);
      CREATE TABLE fx.customers (id serial PRIMARY KEY, email varchar(40) NOT NULL, mood fx.mood,
                                 CHECK (email <> ''));
      CREATE UNIQUE INDEX customers_email ON fx.customers (lower(email));
      CREATE TABLE fx.orders (id bigserial PRIMARY KEY, customer_id integer NOT NULL REFERENCES fx.customers,
                              qty fx.qty, placed date NOT NULL DEFAULT '2026-01-01', span int4range,
                              tags varchar(10)[], mood fx.mood, UNIQUE (customer_id, placed));
      CREATE FUNCTION fx.bump(integer) RETURNS integer LANGUAGE sql VOLATILE AS $$ SELECT $1 $$;
    SQL
  end

  describe "rewrite-test's scenarios" do
    # The query's own operators resolve on the search_path, as they do in
    # production, so it compares only types nothing here plants an
    # operator for.
    let(:parse) do
      PgQuery.parse(<<~SQL)
        SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.mood > o.mood
        WHERE o.qty > 3 AND c.mood <= 'happy' AND o.placed >= '2026-02-01' AND c.email >= 'a'
          AND o.span @> 4 AND o.tags = '{x}' AND (o.placed, o.id) > ('2026-02-01', 5)
        ORDER BY o.placed, o.id LIMIT 5
      SQL
    end

    def schema = Quaack::Enclave::ArenaSchema.load_closure(conn, [tn("orders")])
    def scenarios = Quaack::Enclave::Scenarios.build(conn, parse)

    it "reads the same tables, columns, and constraints" do
      baseline = schema
      plant

      expect(bare(schema)).to eq(bare(baseline))
    end

    COUNTS = "SELECT (SELECT pg_catalog.count(*) FROM fx.orders), (SELECT pg_catalog.count(*) FROM fx.customers)"

    it "builds the same scenarios, and each loads as it did" do
      baseline = scenarios
      expect(baseline.values.flatten.map(&:table).uniq).to contain_exactly(tn("orders"), tn("customers"))
      loaded = baseline.transform_values { |rows| runner.with_fixture(rows) { |tx| tx.query(COUNTS).rows } }
      plant

      expect(bare(scenarios)).to eq(bare(baseline))
      expect(scenarios.transform_values { |rows| runner.with_fixture(rows) { |tx| tx.query(COUNTS).rows } })
        .to eq(loaded)
    end
  end

  describe "counterexamples" do
    let(:map) { { "$1" => { "value" => "3", "type" => "integer" } } }

    def prepare(*inserts)
      Quaack::Enclave::Counterexamples.prepare(conn, inserts, placeholder_map: map,
                                                              tables: %w[customers orders].map { tn(it) })
    end

    def outcome(prepared)
      [prepared.refused, prepared.inserts, prepared.rows,
       runner.with_fixture(prepared.rows, inserts: prepared.inserts) do |tx|
         tx.query("SELECT o.qty, o.placed::pg_catalog.text, o.span::pg_catalog.text FROM fx.orders o " \
                  "ORDER BY o.id").rows
       end]
    end

    it "accepts, refuses, adds parents, and loads as with nothing planted" do
      inserts = ["INSERT INTO fx.orders (customer_id, qty, placed, span) VALUES (7, $1, 'today', '[1,5)')",
                 "INSERT INTO fx.orders (customer_id, qty, placed) VALUES (8, fx.bump(1), '2026-03-01')",
                 "INSERT INTO fx.orders (customer_id, qty, placed) VALUES (1, pg_catalog.abs(-2), '2026-03-02')",
                 "INSERT INTO fx.customers (email) VALUES ('z@example.com')"]
      baseline = outcome(prepare(*inserts))
      # setval isn't rolled back, so the load must advance them again, past
      # the parent customer 1, before the customer the last insert adds.
      conn.exec("ALTER SEQUENCE fx.customers_id_seq RESTART; ALTER SEQUENCE fx.orders_id_seq RESTART")
      plant

      expect(bare(outcome(prepare(*inserts)))).to eq(bare(baseline))
    end
  end

  it "counts arena's tables and finds the ones with user triggers" do
    conn.exec("CREATE FUNCTION fx.noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$")
    conn.exec("CREATE TRIGGER t BEFORE INSERT ON fx.orders FOR EACH ROW EXECUTE FUNCTION fx.noop()")
    count = Integer(conn.exec("SELECT pg_catalog.count(*) FROM pg_catalog.pg_tables " \
                              "WHERE schemaname OPERATOR(pg_catalog.<>) ALL ('{pg_catalog,information_schema}')")
                        .getvalue(0, 0))
    plant

    expect([conn.exec(Quaack::Enclave::Arena::TABLE_COUNT_SQL).values,
            conn.exec(Quaack::Enclave::Arena::USER_TRIGGER_TABLES_SQL).values])
      .to eq([[[count.to_s]], [%w[fx orders]]])
    expect(count).to be >= 2
  end

  it "finds the foreign keys on a denormalized copy's column" do
    plant

    expect(conn.exec_params(Quaack::Enclave::DenormalizedFixture::FOREIGN_KEYS, ["fx.orders", "customer_id"]).values)
      .to eq([["orders_customer_id_fkey"]])
  end

  it "arms each statement's timeout when public's set_config does nothing" do
    plant
    conn.exec("CREATE FUNCTION public.set_config(pg_catalog.text, pg_catalog.text, pg_catalog.bool) " \
              "RETURNS pg_catalog.text LANGUAGE sql AS $$ SELECT $2 $$")
    runner = Quaack::Enclave::ArenaRunner.new(conn, statement_timeout_ms: 50)

    expect { runner.with_fixture([]) { it.query("SELECT pg_catalog.pg_sleep(1)") } }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { expect(it.rule).to eq(:statement_timeout) }
  end
end
