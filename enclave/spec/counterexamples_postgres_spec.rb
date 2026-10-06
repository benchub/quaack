# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "pg_query"
require "quaack/enclave/counterexamples"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/racetrack"

# llm-counterexamples, the enclave's half: bind the real literals into the LLM's
# shape-level inserts, send them through the inbound check, and fill
# foreign-key gaps with parent rows built by the rewrite-test rules.
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

  def customer_of_order(prepared)
    load(prepared, "SELECT c.id, c.root_customer_id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id")
  end

  it "leaves a parent's nullable self-referencing foreign key NULL" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN root_customer_id integer REFERENCES fx.customers")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')")
    expect(customer_of_order(prepared)).to eq([["7", nil]])
  end

  it "points a parent's NOT NULL self-referencing foreign key at the parent itself" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN root_customer_id integer NOT NULL REFERENCES fx.customers")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')")
    expect(customer_of_order(prepared)).to eq([%w[7 7]])
  end

  it "points a parent's NOT NULL self-referencing foreign key at the parent itself when the key it references " \
     "isn't set" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN code integer NOT NULL UNIQUE,
                 ADD COLUMN root_code integer NOT NULL REFERENCES fx.customers (code)")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')")
    expect(load(prepared, "SELECT id, code = root_code FROM fx.customers")).to eq([%w[7 t]])
  end

  it "varies a parent's unique-key column that has no CHECK over one whose CHECK allows few values" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN kind integer NOT NULL CHECK (kind IN (1, 2)),
                 ADD COLUMN login text NOT NULL;
               CREATE UNIQUE INDEX customers_kind_login ON fx.customers (kind, login)")
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a'), (2, 8, 'b'), (3, 9, 'c')")
    expect(load(prepared, "SELECT kind, count(DISTINCT login) FROM fx.customers GROUP BY 1")).to eq([%w[1 3]])
  end

  it "refuses a parent whose unique column rewrite-test can't fill, naming the parent's table, column, and type" do
    conn.exec("ALTER TABLE fx.customers ADD COLUMN lsn pg_lsn NOT NULL UNIQUE")
    expect { prepare("INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, $1)") }
      .to raise_error(Quaack::Enclave::Scenarios::Error) { |e|
        expect([e.rule, e.column]).to eq([:unsupported_type,
                                          { "table" => "fx.customers", "column" => "lsn", "type" => "pg_lsn" }])
        expect(e.message).not_to include("SENTINEL")
      }
  end

  describe "a parent's nullable column of a type rewrite-test can't fill" do
    let(:insert) { "INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')" }
    let(:joined) { "SELECT o.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id" }

    before { conn.exec("ALTER TABLE fx.customers ADD COLUMN lsn pg_lsn, ADD COLUMN ulsn pg_lsn UNIQUE") }

    def prepare_for(*queries)
      described_class.prepare(conn, [insert], placeholder_map: map, tables: %w[customers orders].map { tn(it) },
                                              queries:)
    end

    def lsn_refusal
      raise_error(Quaack::Enclave::Scenarios::Error) { |e| expect(e.rule).to eq(:unsupported_type) }
    end

    it "is left NULL, unique or not, when neither query reads it" do
      prepared = prepare_for(joined, "#{joined} WHERE o.status = 'a'")
      expect(load(prepared, "SELECT id, lsn, ulsn FROM fx.customers")).to eq([["7", nil, nil]])
    end

    it "is refused when either query reads it, or when no queries are given" do
      expect { prepare_for(joined, "SELECT o.id, c.lsn FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id") }
        .to lsn_refusal
      expect { prepare_for("SELECT c.* FROM fx.customers c", joined) }.to lsn_refusal
      expect { prepare(insert) }.to lsn_refusal
    end

    it "is refused when a CHECK rejects NULL" do
      conn.exec("ALTER TABLE fx.customers DROP COLUMN ulsn, ADD CHECK (lsn IS NOT NULL)")
      expect { prepare_for(joined) }.to lsn_refusal
    end
  end

  it "refuses an insert the inbound check refuses, or one with an unknown placeholder, by rule alone" do
    prepared = prepare("INSERT INTO fx.orders (id, customer_id, status) SELECT 1, 2, 'x'",
                       "INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, $9)",
                       "INSERT INTO fx.customers (id, name, tier) VALUES (7, $1, 'gold')")
    expect(prepared.refused).to eq([{ index: 0, rule: "insert_select" }, { index: 1, rule: "unknown_placeholder" }])
    expect(prepared.inserts.size).to eq(1)
    expect(prepared.refused.to_s).not_to include("SENTINEL_10a")
  end

  describe "an insert with a value Postgres can't evaluate (20261003-24)" do
    # $1 binds to the sentinel, and casting it to integer fails with the
    # value in Postgres's message.
    let(:good) { "INSERT INTO fx.orders (id, customer_id, status) VALUES (1, 7, 'a')" }

    # Everything prepare gives back, as one String: what it returns, real
    # values included, or the error it raises, with its message, full
    # message, and every cause's.
    def everything_from
      prepared = yield
      [prepared.inspect, prepared.rows.map { [it.table.to_s, it.columns, it.values] }, prepared.inserts.map(&:to_s),
       prepared.refused].to_s
    rescue StandardError => e
      error_chain(e)
    end

    def error_chain(error)
      chain = []
      while error
        chain << [error.class.name, error.message, error.full_message(highlight: false)]
        error = error.cause
      end
      chain.to_s
    end

    it "refuses it by rule alone, and loads the rest, when the value is a foreign key" do
      sql = "INSERT INTO fx.orders (id, customer_id, status) VALUES (2, $1::integer, 'b')"
      expect(everything_from { prepare(good, sql) }).not_to include("SENTINEL_10a")
      prepared = prepare(good, sql)
      expect(prepared.refused).to eq([{ index: 1, rule: "bad_value" }])
      expect(prepared.inserts.size).to eq(1)
      expect(load(prepared, "SELECT o.id, c.id FROM fx.orders o JOIN fx.customers c ON c.id = o.customer_id"))
        .to eq([%w[1 7]])
    end

    it "refuses it by rule alone when the value is in a column with no foreign key" do
      sql = "INSERT INTO fx.orders (id, customer_id, status, qty) VALUES (2, 7, 'b', $1::integer)"
      expect(everything_from { prepare(good, sql) }).not_to include("SENTINEL_10a")
      expect(prepare(good, sql).refused).to eq([{ index: 1, rule: "bad_value" }])
    end

    it "refuses it by rule alone when a domain's CHECK rejects the value (class 23)" do
      conn.exec("CREATE DOMAIN fx.small AS integer CHECK (VALUE < 3)")
      sql = "INSERT INTO fx.orders (id, customer_id, status, qty) VALUES (2, 7, $1, $2::fx.small)"
      expect(everything_from { prepare(good, sql) }).not_to include("SENTINEL_10a")
      prepared = prepare(good, sql)
      expect(prepared.refused).to eq([{ index: 1, rule: "bad_value" }])
      expect(prepared.inserts.size).to eq(1)
    end

    # Postgres's message for this quotes the query, value and all.
    it "refuses it by rule alone when the value's expression doesn't type-check (class 42)" do
      sql = "INSERT INTO fx.orders (id, customer_id, status, qty) VALUES (2, 7, 'b', abs($1::text))"
      expect(everything_from { prepare(good, sql) }).not_to include("SENTINEL_10a")
      prepared = prepare(good, sql)
      expect(prepared.refused).to eq([{ index: 1, rule: "bad_value" }])
      expect(prepared.inserts.size).to eq(1)
    end

    # Each call to fx.slow sleeps, so evaluating a fx.slow_int value takes
    # long enough to be timed out or have its backend terminated. It claims
    # IMMUTABLE so the inbound check lets the cast through.
    describe "when evaluating it fails for a reason that isn't the value" do
      let(:slow) { "INSERT INTO fx.orders (id, customer_id, status, qty) VALUES (2, 7, $1, $2::fx.slow_int)" }

      before do
        conn.exec(<<~SQL)
          CREATE FUNCTION fx.slow(integer) RETURNS boolean LANGUAGE plpgsql IMMUTABLE
            AS 'BEGIN PERFORM pg_sleep(5); RETURN true; END';
          CREATE DOMAIN fx.slow_int AS integer CHECK (fx.slow(VALUE));
        SQL
      end

      def sleeping?(watcher, pid)
        watcher.exec_params("SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event = 'PgSleep'", [pid])
               .ntuples == 1
      end

      it "lets a statement timeout go up, not as bad_value, with no value in it" do
        conn.exec("SET statement_timeout = 300")
        expect(everything_from { prepare(good, slow) }).not_to include("SENTINEL_10a")
        expect { prepare(good, slow) }.to raise_error(PG::QueryCanceled)
      end

      it "lets a terminated connection go up, not as bad_value, with no value in it" do
        watcher = racetrack_and_arena.arena.connect
        pid = conn.backend_pid
        killer = Thread.new do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
          sleep 0.05 until sleeping?(watcher, pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          watcher.exec_params("SELECT pg_terminate_backend($1)", [pid])
        end
        outcome = everything_from { prepare(good, slow) }
        killer.join
        # Raised by Evaluated itself: a later query would fail with
        # "PQsocket() can't get socket descriptor" instead.
        expect(outcome).to include("PG::ConnectionBad", "terminating connection due to administrator command")
        expect(outcome).not_to include("SENTINEL_10a")
      ensure
        killer&.kill
        watcher&.close
      end
    end

    it "has a leak check that catches a planted sentinel, in what prepare returns or in an error's cause" do
      planted = described_class::Prepared.new(rows: [], inserts: ["SENTINEL_10a"], refused: [])
      expect(everything_from { planted }).to include("SENTINEL_10a")
      expect(everything_from do
        raise PG::Error, "SENTINEL_10a"
      rescue PG::Error
        raise ArgumentError, "no value here"
      end).to include("SENTINEL_10a")
    end
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

  describe "a placeholder whose literal is a clock word (task 20261004-95)" do
    let(:map) do
      { "$1" => { "value" => " Today ", "type" => "unknown" }, "$2" => { "value" => "NOW", "type" => "unknown" },
        "$3" => { "value" => "tomorrow", "type" => "unknown" } }
    end

    before do
      conn.exec("CREATE TABLE fx.stamps (id integer PRIMARY KEY, day date, at timestamptz, local timestamp,
                   note text, days daterange, due date)")
      Quaack::Enclave::Racetrack.create_clock_anchor(conn, "'2024-03-09 23:30:00+00'::pg_catalog.timestamptz")
      conn.exec("SET TimeZone = 'Pacific/Chatham'")
    end

    def stamps(*inserts) = described_class.prepare(conn, inserts, placeholder_map: map, tables: [tn("stamps")])

    it "binds the clock anchor's value, in the session's TimeZone, where the word would read the clock" do
      prepared = stamps("INSERT INTO fx.stamps (id, day, at, local, note, days, due)
                         VALUES (1, $1, $2, $2::timestamp, $1, daterange($1, NULL), $3)")
      expect(prepared.refused).to eq([])
      expect(load(prepared, "SELECT day::text, at = '2024-03-09 23:30:00+00', local::text, note, days::text, due::text
                             FROM fx.stamps"))
        .to eq([["2024-03-10", "t", "2024-03-10 13:15:00", " Today ", "[2024-03-10,)", "2024-03-11"]])
    end

    it "binds the clock anchor's value for a word in a nested ARRAY" do
      conn.exec("ALTER TABLE fx.stamps ADD COLUMN dates date[]")
      prepared = stamps("INSERT INTO fx.stamps (id, dates) VALUES (1, ARRAY[ARRAY[$3], ARRAY[$1]]::date[])")
      expect(prepared.refused).to eq([])
      expect(load(prepared, "SELECT dates::text FROM fx.stamps")).to eq([["{{2024-03-11},{2024-03-10}}"]])
    end

    it "still refuses a clock word the insert writes itself" do
      expect(stamps("INSERT INTO fx.stamps (id, day) VALUES (1, 'today')").refused)
        .to eq([{ index: 0, rule: "clock_literal" }])
    end
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
