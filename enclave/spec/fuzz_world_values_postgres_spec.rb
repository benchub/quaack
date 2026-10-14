# frozen_string_literal: true

require "quaack/enclave/fuzz"

# The fuzz search's values from world knowledge, and its many copies of a row
# (task 20261012-13, DESIGN.md's rewrite-test): each pair here is a wrong
# rewrite from 20261012-5's hard corpus that only a value nowhere near the
# queries' constants, or more than 4 rows in a table, tells apart.
RSpec.describe "Quaack::Enclave::Fuzz's value classes and copies" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:stop) { Quaack::Enclave::Fuzz::StopRule.trials(1500) }

  def fuzz(original, candidate, stop: self.stop) = Quaack::Enclave::Fuzz.run(conn, original, candidate, stop:)

  def table(ddl) = conn.exec("CREATE SCHEMA IF NOT EXISTS w; #{ddl}")

  shared_examples "a disproof" do |ddl, original, candidate|
    it "disproves #{candidate}" do
      table(ddl)

      expect(fuzz(original, candidate).verdict).to eq(:disproved)
    end
  end

  describe "text" do
    include_examples "a disproof", "CREATE TABLE w.products (id bigint PRIMARY KEY, code text NOT NULL)",
                     "SELECT id FROM w.products WHERE trim(code) = 'ABC'",
                     "SELECT id FROM w.products WHERE code = 'ABC'"
    include_examples "a disproof", "CREATE TABLE w.profiles (id bigint PRIMARY KEY, nickname text)",
                     "SELECT id FROM w.profiles WHERE nullif(trim(nickname), '') IS NOT NULL",
                     "SELECT id FROM w.profiles WHERE nickname <> ''"
    include_examples "a disproof", "CREATE TABLE w.accounts (id bigint PRIMARY KEY, username text NOT NULL)",
                     "SELECT id FROM w.accounts WHERE upper(username) = upper('sam')",
                     "SELECT id FROM w.accounts WHERE lower(username) = lower('sam')"
    include_examples "a disproof", "CREATE TABLE w.units (id bigint PRIMARY KEY, code text NOT NULL)",
                     "SELECT id FROM w.units WHERE lower(code) = 'kelvin'",
                     "SELECT id FROM w.units WHERE upper(code) = 'KELVIN'"
    include_examples "a disproof", "CREATE TABLE w.people (id bigint PRIMARY KEY, name text NOT NULL)",
                     "SELECT id FROM w.people WHERE pg_catalog.normalize(name, 'NFC') = 'José'",
                     "SELECT id FROM w.people WHERE name = 'José'"
    include_examples "a disproof", "CREATE TABLE w.cities (id bigint PRIMARY KEY, name text NOT NULL)",
                     "SELECT id FROM w.cities WHERE char_length(name) <= 10",
                     "SELECT id FROM w.cities WHERE octet_length(name) <= 10"
    include_examples "a disproof", "CREATE TABLE w.users (id bigint PRIMARY KEY, email text NOT NULL UNIQUE)",
                     "SELECT count(DISTINCT lower(email)) FROM w.users",
                     "SELECT count(*) FROM w.users"
    include_examples "a disproof", "CREATE TABLE w.contacts (id bigint PRIMARY KEY, email text NOT NULL)",
                     "SELECT id FROM w.contacts WHERE split_part(email, '@', 2) = 'example.org'",
                     "SELECT id FROM w.contacts WHERE email LIKE '%@example.org'"
  end

  describe "numbers" do
    include_examples "a disproof", "CREATE TABLE w.ledgers (id bigint PRIMARY KEY, balance numeric(14, 2) NOT NULL)",
                     "SELECT id FROM w.ledgers WHERE balance > 0",
                     "SELECT id FROM w.ledgers WHERE sign(balance) = 1"
    include_examples "a disproof", "CREATE TABLE w.gauges (id bigint PRIMARY KEY, level numeric NOT NULL)",
                     "SELECT id FROM w.gauges WHERE level > 1000",
                     "SELECT id FROM w.gauges WHERE level::numeric(20, 6) > 1000"
    include_examples "a disproof",
                     "CREATE TABLE w.ratings (id bigint PRIMARY KEY, stars double precision NOT NULL " \
                     "CHECK (stars BETWEEN 0 AND 5))",
                     "SELECT id, round(stars)::integer AS rounded FROM w.ratings",
                     "SELECT id, round(stars::numeric)::integer AS rounded FROM w.ratings"
    include_examples "a disproof",
                     "CREATE TABLE w.scores (id bigint PRIMARY KEY, points integer NOT NULL, " \
                     "possible integer NOT NULL CHECK (abs(possible) < 1000))",
                     "SELECT id FROM w.scores WHERE points / possible >= 1",
                     "SELECT id FROM w.scores WHERE points >= possible"
    include_examples "a disproof",
                     "CREATE TABLE w.counters (id bigint PRIMARY KEY, " \
                     "hits bigint NOT NULL CHECK (hits >= 0 AND hits < 5000000000))",
                     "SELECT id FROM w.counters WHERE hits::bigint > 7",
                     "SELECT id FROM w.counters WHERE hits::integer > 7"

    # 20261012-10/-11: an original that fails disproves nothing. Zero, NaN,
    # the infinities and int4's edges make it fail often; those worlds are
    # thrown away, and still the search compares a good share of its worlds
    # (here about a third, as many as without these values).
    it "throws away the worlds where these values make the original fail" do
      table("CREATE TABLE w.rates (id bigint PRIMARY KEY, hits integer NOT NULL, visits integer NOT NULL, " \
            "level numeric NOT NULL)")

      outcome = fuzz("SELECT id, hits / visits AS rate, level::integer AS whole FROM w.rates",
                     "SELECT id, hits / nullif(visits, 0) AS rate, CASE WHEN level > -2147483648.5 AND " \
                     "level < 2147483647.5 THEN level::integer END AS whole FROM w.rates")

      expect(outcome.verdict).to eq(:passed)
      expect(outcome.trials).to be >= 1500 / 4
    end
  end

  describe "dates and times" do
    include_examples "a disproof", "CREATE TABLE w.orders (id bigint PRIMARY KEY, ordered_on date NOT NULL)",
                     "SELECT id FROM w.orders WHERE extract(isoyear FROM ordered_on) = 2025 " \
                     "AND extract(week FROM ordered_on) = 1",
                     "SELECT id FROM w.orders WHERE extract(year FROM ordered_on) = 2025 " \
                     "AND extract(week FROM ordered_on) = 1"
    include_examples "a disproof", "CREATE TABLE w.shifts (id bigint PRIMARY KEY, work_date date NOT NULL)",
                     "SELECT id FROM w.shifts WHERE extract(dow FROM work_date) IN (0, 6)",
                     "SELECT id FROM w.shifts WHERE extract(isodow FROM work_date) IN (0, 6)"
    include_examples "a disproof", "CREATE TABLE w.payments (id bigint PRIMARY KEY, paid_on date NOT NULL)",
                     "SELECT id FROM w.payments WHERE date_trunc('quarter', paid_on) = '2024-04-01'",
                     "SELECT id FROM w.payments WHERE extract(month FROM paid_on) BETWEEN 4 AND 6"
    include_examples "a disproof",
                     "CREATE TABLE w.subscriptions (id bigint PRIMARY KEY, expires_at timestamp NOT NULL)",
                     "SELECT id FROM w.subscriptions WHERE extract(epoch FROM expires_at)::bigint > 1700000000",
                     "SELECT id FROM w.subscriptions WHERE extract(epoch FROM expires_at)::integer > 1700000000"
    include_examples "a disproof", "CREATE TABLE w.views (id bigint PRIMARY KEY, viewed_at timestamptz NOT NULL)",
                     "SELECT date_trunc('hour', viewed_at AT TIME ZONE 'America/New_York') AS hour, count(*) AS n " \
                     "FROM w.views GROUP BY 1",
                     "SELECT date_trunc('hour', (viewed_at - interval '5 hours') AT TIME ZONE 'UTC') AS hour, " \
                     "count(*) AS n FROM w.views GROUP BY 1"
    include_examples "a disproof", "CREATE TABLE w.visits (id bigint PRIMARY KEY, placed_at timestamptz NOT NULL)",
                     "SELECT id, to_char(placed_at AT TIME ZONE 'Europe/London', 'YYYY-MM-DD') AS day FROM w.visits",
                     "SELECT id, to_char(placed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS day FROM w.visits"
  end

  describe "JSON" do
    include_examples "a disproof", "CREATE TABLE w.customers (id bigint PRIMARY KEY, data jsonb NOT NULL)",
                     %(SELECT id FROM w.customers WHERE data @> '{"tags": ["vip"]}'),
                     "SELECT id FROM w.customers WHERE data->'tags' ? 'vip'"
    include_examples "a disproof", "CREATE TABLE w.records (id bigint PRIMARY KEY, data jsonb NOT NULL)",
                     "SELECT id FROM w.records WHERE data->>'deleted_at' IS NULL",
                     "SELECT id FROM w.records WHERE NOT (data ? 'deleted_at')"
    include_examples "a disproof", "CREATE TABLE w.groups (id bigint PRIMARY KEY, data jsonb NOT NULL)",
                     "SELECT id FROM w.groups WHERE data->'member_ids' @> '[5]'",
                     "SELECT id FROM w.groups WHERE data->'member_ids' ? '5'"
    include_examples "a disproof", "CREATE TABLE w.listings (id bigint PRIMARY KEY, data jsonb NOT NULL)",
                     "SELECT id FROM w.listings WHERE (data->>'price')::numeric = 10",
                     "SELECT id FROM w.listings WHERE data->>'price' = '10'"
    include_examples "a disproof", "CREATE TABLE w.carts (id bigint PRIMARY KEY, data jsonb NOT NULL)",
                     "SELECT id FROM w.carts WHERE (data->>'qty')::integer > 5",
                     "SELECT id FROM w.carts WHERE data->'qty' > '5'::jsonb"
  end

  describe "arrays" do
    include_examples "a disproof", "CREATE TABLE w.products (id bigint PRIMARY KEY, tags text[] NOT NULL)",
                     "SELECT id FROM w.products WHERE NOT ('sale' = ANY (tags))",
                     "SELECT id FROM w.products WHERE NOT (tags @> ARRAY['sale'])"
    include_examples "a disproof", "CREATE TABLE w.products (id bigint PRIMARY KEY, tags text[] NOT NULL)",
                     "SELECT id FROM w.products WHERE tags = ARRAY['a', 'b']",
                     "SELECT id FROM w.products WHERE tags @> ARRAY['a', 'b'] AND tags <@ ARRAY['a', 'b']"
  end

  describe "many copies of a row" do
    include_examples "a disproof",
                     "CREATE TABLE w.orders (id bigint PRIMARY KEY, customer_id bigint NOT NULL, total int NOT NULL)",
                     "SELECT customer_id, count(*) AS n FROM w.orders GROUP BY customer_id HAVING count(*) > 5",
                     "SELECT customer_id, count(*) AS n FROM w.orders GROUP BY customer_id HAVING count(*) >= 5"
    include_examples "a disproof",
                     "CREATE TABLE w.sales (id bigint PRIMARY KEY, store_id integer NOT NULL, " \
                     "amount integer NOT NULL CHECK (amount >= 0))",
                     "SELECT store_id FROM w.sales GROUP BY store_id HAVING count(*) > 20 AND avg(amount) > 100",
                     "SELECT store_id FROM w.sales WHERE amount > 100 GROUP BY store_id HAVING count(*) > 20"
    include_examples "a disproof", "CREATE TABLE w.prices (day date PRIMARY KEY, cents integer NOT NULL)",
                     "SELECT day, sum(cents) OVER (ORDER BY day ROWS BETWEEN 9 PRECEDING AND CURRENT ROW) AS s " \
                     "FROM w.prices ORDER BY day",
                     "SELECT day, sum(cents) OVER (ORDER BY day ROWS BETWEEN 10 PRECEDING AND CURRENT ROW) AS s " \
                     "FROM w.prices ORDER BY day"
    include_examples "a disproof",
                     "CREATE TABLE w.users (id bigint PRIMARY KEY, name text NOT NULL); " \
                     "CREATE TABLE w.orders (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES w.users)",
                     "SELECT u.id FROM w.users u WHERE (SELECT count(*) FROM w.orders o WHERE o.user_id = u.id) > 20",
                     "SELECT u.id FROM w.users u WHERE EXISTS " \
                     "(SELECT 1 FROM w.orders o WHERE o.user_id = u.id ORDER BY o.id OFFSET 21)"
    include_examples "a disproof",
                     "CREATE TABLE w.submissions (id bigint PRIMARY KEY, course_id bigint NOT NULL, " \
                     "assignment_id bigint NOT NULL, user_id bigint NOT NULL, UNIQUE (assignment_id, user_id))",
                     "SELECT course_id FROM w.submissions GROUP BY course_id HAVING count(DISTINCT user_id) > 10",
                     "SELECT course_id FROM w.submissions GROUP BY course_id HAVING count(*) > 10"

    # The user (2026-10-12): a size past 4 rows leaves as 5, "5 or more", so
    # no size can carry a query's constant. 38 rows tell these apart, in
    # about one world in 600.
    it "gives a disproof's size past 4 rows in a table as 5, never the count the query's constant asked for" do
      table("CREATE TABLE w.notes (id bigint PRIMARY KEY, user_id bigint NOT NULL, unread boolean NOT NULL)")

      outcome = fuzz("SELECT count(*) FROM (SELECT id FROM w.notes WHERE user_id = 7 AND unread " \
                     "ORDER BY id LIMIT 37) s",
                     "SELECT count(*) FROM w.notes WHERE user_id = 7 AND unread",
                     stop: Quaack::Enclave::Fuzz::StopRule.trials(4000))

      expect(outcome).to have_attributes(verdict: :disproved, sizes: [["w", "notes", 5]])
    end

    # A world whose ordinary draw gives the copies' parent no rows still
    # gives it one, so the copies have a row to point at and load.
    it "gives the table the copies' foreign key points to a row when its draw gave none" do
      table("CREATE TABLE w.users (id bigint PRIMARY KEY, name text NOT NULL); " \
            "CREATE TABLE w.orders (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES w.users)")
      sql = "SELECT u.id FROM w.users u WHERE (SELECT count(*) FROM w.orders o WHERE o.user_id = u.id) > 20"
      fuzz = Quaack::Enclave::Fuzz
      catalog = fuzz::Catalog.new(conn, fuzz.footprint([sql]))
      generator = fuzz::Generator.new(catalog, fuzz::Domains.new(conn, catalog, [sql]))
      users, orders = %w[users orders].map { |name| generator.order.find { it.name == name } }
      config = fuzz::Generator::Config.new(
        rows: { users => 0, orders => 0 }, key_pool: 2, null_rate: 0.0, literal_bias: 0.8, dup_rate: 0.0,
        boundary_rate: 0.0, world_rate: 0.0, copies: fuzz::Generator::Copies.new(table: orders, count: 21, vary: 0.0)
      )
      allow(fuzz::Generator).to receive(:config).and_return(config)

      rows = generator.world(Random.new(1))
      rows.each do |row|
        columns = row.cells.keys.map { conn.quote_ident(it) }.join(", ")
        values = row.cells.values.map { it.nil? ? "NULL" : conn.escape_literal(it) }.join(", ")
        conn.exec("INSERT INTO #{row.table} (#{columns}) VALUES (#{values})")
      end

      expect(conn.exec("SELECT count(*) FROM w.users").getvalue(0, 0).to_i).to eq(1)
      expect(conn.exec("SELECT count(*) FROM w.orders WHERE user_id IS NOT NULL").getvalue(0, 0).to_i).to eq(21)
    end

    it "ignores a constant past 100" do
      table("CREATE TABLE w.notes (id bigint PRIMARY KEY, user_id bigint NOT NULL, unread boolean NOT NULL)")

      outcome = fuzz("SELECT count(*) FROM (SELECT id FROM w.notes WHERE user_id = 7 AND unread " \
                     "ORDER BY id LIMIT 101) s",
                     "SELECT count(*) FROM w.notes WHERE user_id = 7 AND unread")

      expect(outcome.verdict).to eq(:passed)
    end
  end

  describe Quaack::Enclave::Fuzz::WorldValues do
    def world(*sqls)
      facts = Quaack::Enclave::Fuzz::Facts.new(sqls.map { PgQuery.parse(it).tree.to_h })
      described_class.new(conn, facts)
    end

    it "copies each integer constant from 1 to 100 and one either side, and ignores the rest" do
      expect(world("SELECT id FROM w.t WHERE n > 0 AND m < 1 AND k <> 101 AND j = -4 LIMIT 37 OFFSET 2.5").copies)
        .to eq([1, 2, 36, 37, 38])
    end

    it "takes DST from the zones the queries name, or else New York, London and Sydney" do
      chicago = world("SELECT id FROM w.t WHERE (at AT TIME ZONE 'America/Chicago') > '2024-01-01'")
      instants = chicago.values("timestamp with time zone", "at")
      expect(instants).to include("2024-03-10 08:00:00+00", "2024-11-03 07:00:00+00")
      expect(instants).not_to include("2024-03-31 01:00:00+00")
      expect(chicago.values("timestamp without time zone",
                            "at")).to include("2024-03-10 01:00:00", "2024-03-10 03:00:00")

      fallback = world("SELECT id FROM w.t WHERE (at AT TIME ZONE 'UTC') > '2024-01-01'").values(
        "timestamp with time zone", "at"
      )
      expect(fallback).to include("2024-03-10 07:00:00+00", "2024-03-31 01:00:00+00", "2024-04-06 16:00:00+00")
    end

    it "makes a column's text classes from the queries' strings, separators and LIKE patterns" do
      values = world("SELECT id FROM w.t WHERE split_part(s, '|', 2) = 'Kid' AND s LIKE 'a#%'").values("text", "s")
      expect(values).to include("", "   ", " Kid", "Kid\n", "KID", "kid", "\u212Aid", "a|b|c", "a#x#y")
    end

    it "gives JSON each type for a key the queries read, and arrays NULL, repeats and another order" do
      values = world("SELECT id FROM w.t WHERE data->>'price' = '10'").values("jsonb", "data")
      expect(values).to include('{"price":10}', '{"price":"10"}', '{"price":10.0}', '{"price":null}', "{}",
                                '{"price":[10]}')
      arrays = world("SELECT id FROM w.t WHERE tags @> ARRAY['a', 'b']").values("text[]", "tags")
      expect(arrays).to include("{NULL}", "{a,NULL}", "{a,a}", "{b,a}")
    end

    it "gives numbers NaN, the infinities, halves, and a divided-by or int-cast column 0, negatives and int4's edges" do
      values = world("SELECT id FROM w.t WHERE a / b > 1 AND c::integer > 2").values("numeric", "b")
      expect(values).to include("NaN", "Infinity", "-Infinity", "0.5", "-0.5", "2.5", "0", "-1", "2147483648",
                                "-2147483649")
      expect(world("SELECT id FROM w.t WHERE a / b > 1").values("integer", "a")).to be_empty
    end

    it "gives dates the year's end, a Sunday, the same date a year either side, and the infinities" do
      values = world("SELECT id FROM w.t WHERE d = '2025-06-11'").values("date", "d")
      expect(values).to include("2025-12-29", "2026-01-03", "2024-12-31", "2025-06-15", "2024-06-11", "2026-06-11",
                                "infinity", "-infinity")
    end
  end
end
