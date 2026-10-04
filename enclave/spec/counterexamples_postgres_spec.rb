# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "pg_query"
require "quaack/enclave/counterexamples"
require "quaack/enclave/predicate_atoms"

# 10a, the enclave's half: bind the real literals into the LLM's
# shape-level inserts, send them through the inbound check, and fill
# foreign-key gaps with parent rows built by the step 9 rules.
RSpec.describe Quaack::Enclave::Counterexamples do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:map) do
    { "$1" => { "value" => "SENTINEL_10a", "type" => "unknown" }, "$2" => { "value" => "3", "type" => "integer" } }
  end

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.customers (id integer PRIMARY KEY, name text NOT NULL,
        tier text NOT NULL CHECK (tier IN ('gold', 'silver')));
      CREATE TABLE fx.orders (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES fx.customers,
        status text NOT NULL, qty integer);
      CREATE TABLE fx.items (id integer PRIMARY KEY, order_id integer NOT NULL REFERENCES fx.orders);
    SQL
  end

  def prepare(*inserts)
    described_class.prepare(conn, inserts, placeholder_map: map, tables: %w[customers orders items].map { tn(it) })
  end

  def load(prepared, sql) = runner.with_fixture(prepared.rows, inserts: prepared.inserts) { |tx| tx.query(sql).rows }

  it "binds the real literals and adds the missing parent row, which satisfies its CHECK" do
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status, qty) VALUES (1, 7, $1, $2)")
    expect(prepared.refused).to eq([])
    expect(prepared.rows.map { |r| [r.table.name, r.values[r.columns.index("id")]] }).to eq([%w[customers 7]])
    expect(load(prepared,
                "SELECT o.status, o.qty, c.tier FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id"))
      .to eq([%w[SENTINEL_10a 3 gold]])
  end

  it "adds no parent that another insert supplies, and loads parents' inserts first" do
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')",
                       "INSERT INTO fx.customers (id, name, tier) VALUES (7, 'n', 'silver')")
    expect(prepared.rows).to eq([])
    expect(prepared.inserts.map { it[/fx\.\w+/] }).to eq(%w[fx.customers fx.orders])
    expect(load(prepared, "SELECT count(*) FROM fx.orders")).to eq([["1"]])
  end

  it "fills a gap two levels up, grandparents first" do
    prepared = prepare("INSERT INTO fx.items (id, order_id) VALUES (1, 5)")
    expect(prepared.rows.map { it.table.name }).to eq(%w[customers orders])
    expect(load(prepared, "SELECT count(*) FROM fx.items i JOIN fx.orders o ON o.id = i.order_id")).to eq([["1"]])
  end

  it "gives parents distinct values on unique indexes and on unique columns with a default" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN email text NOT NULL DEFAULT '',
                 ADD COLUMN code text NOT NULL DEFAULT 'x' UNIQUE;
               CREATE UNIQUE INDEX customers_email ON fx.customers (email)")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a'), (2, 8, 'b')")
    expect(load(prepared, "SELECT count(DISTINCT c.email) FROM fx.customers c")).to eq([["2"]])
  end

  it "varies one column of a parent's multi-column unique index, and gives the rest their typical value" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN root_account_ids bigint[] NOT NULL, ADD COLUMN login text NOT NULL;
               CREATE UNIQUE INDEX customers_login ON fx.customers (root_account_ids, login)")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a'), (2, 8, 'b')")
    expect(load(prepared, "SELECT root_account_ids::text, count(DISTINCT login) FROM fx.customers GROUP BY 1"))
      .to eq([["{}", "2"]])
  end

  it "refuses an insert the inbound check refuses, or one with an unknown placeholder, by rule alone" do
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) SELECT 1, 2, 'x'",
                       "INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, $9)",
                       "INSERT INTO fx.customers (id, name, tier) VALUES (7, $1, 'gold')")
    expect(prepared.refused).to eq([{ index: 0, rule: "insert_select" }, { index: 1, rule: "unknown_placeholder" }])
    expect(prepared.inserts.size).to eq(1)
    expect(prepared.refused.to_s).not_to include("SENTINEL_10a")
  end

  it "builds a parent whose domain column rejects the type-typical value, from the column's CHECK" do
    conn.exec(<<~SQL)
      CREATE DOMAIN fx.code AS integer CHECK (VALUE > 1000);
      CREATE TABLE fx.regions (id integer PRIMARY KEY, code fx.code NOT NULL CHECK (code > 5000));
      CREATE TABLE fx.depots (id integer PRIMARY KEY, region_id integer NOT NULL REFERENCES fx.regions);
    SQL
    prepared = described_class.prepare(conn, ["INSERT INTO fx.depots (id, region_id) VALUES (1, 4)"],
                                       placeholder_map: map, tables: %w[regions depots].map { tn(it) })
    expect(prepared.refused).to eq([])
    expect(load(prepared, "SELECT r.code FROM fx.depots d JOIN fx.regions r ON r.id = d.region_id"))
      .to eq([["5001"]])
  end

  describe "an insert that sets a GENERATED ALWAYS key (task 20260927-24)" do
    before { conn.exec("CREATE TABLE fx.accounts (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text)") }

    def accounts(*inserts)
      described_class.prepare(conn, inserts, placeholder_map: map, tables: [tn("accounts")])
    end

    def compare(prepared)
      sql = "SELECT a.id FROM fx.accounts a"
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql),
                                                      column_names: { tn("accounts") => %w[id name] })
      described_class.compare(runner, prepared, original: sql, candidate: "#{sql} WHERE a.name IS NOT NULL",
                                                atoms:, untested: [])
    end

    it "loads with OVERRIDING SYSTEM VALUE, keeping the id it sets, and disproves" do
      prepared = accounts("INSERT INTO fx.accounts (id, name) OVERRIDING SYSTEM VALUE VALUES (4242, NULL)")
      expect(prepared.refused).to eq([])
      expect(load(prepared, "SELECT id, name FROM fx.accounts")).to eq([["4242", nil]])
      expect(compare(prepared).match).to be(false)
    end

    it "fails its round cleanly as a load failure when the id collides" do
      prepared = accounts("INSERT INTO fx.accounts (id, name) OVERRIDING SYSTEM VALUE VALUES (7, 'a')",
                          "INSERT INTO fx.accounts (id, name) OVERRIDING SYSTEM VALUE VALUES (7, NULL)")
      expect(prepared.refused).to eq([])
      result = compare(prepared)
      expect([result.match, result.load_failed, result.rule]).to eq([nil, true, :insert_failed])
    end
  end
end
