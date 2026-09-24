# frozen_string_literal: true

require "json"
require "pg_query"
require "pp"
require "tmpdir"
require "quaack/enclave/literal_set"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/redaction"
require "quaack/enclave/store"

# README 3e against real statistics. Each example runs 3g and 3c the way the
# run does, then LiteralSet on what they stored.
#
# public.readings has a skewed k: 7 in half the rows, 3 in a tenth, 11 in
# a twentieth, and the row number in the rest, so its MCV list is 7, 3, 11
# and its histogram holds the rest. amount is unique, so it has a histogram
# and no MCV list. label is 'hot' in half the rows. public.fresh.x has its
# statistics target set to 0, so ANALYZE keeps no pg_stats row for it. The
# harness's public.orders.status has an MCV list and no histogram.
RSpec.describe Quaack::Enclave::LiteralSet do
  let(:conn) { test_database.connection }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  around do |example|
    Dir.mktmpdir("quaack-literal-set") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.readings (id integer PRIMARY KEY, k integer NOT NULL, label text NOT NULL,
                                    amount numeric NOT NULL, flag boolean NOT NULL, big bigint NOT NULL);
      INSERT INTO public.readings
      SELECT i, CASE WHEN i % 2 = 0 THEN 7 WHEN i % 10 = 1 THEN 3 WHEN i % 20 = 3 THEN 11 ELSE i + 100 END,
             CASE WHEN i % 2 = 0 THEN 'hot' ELSE 'v' || i END, i * 1.5, i % 3 = 0, i * 1000000000::bigint
      FROM generate_series(1, 10000) AS i;
      CREATE TABLE public.fresh (id integer, x integer);
      INSERT INTO public.fresh SELECT i, i % 4 FROM generate_series(1, 1000) AS i;
      ALTER TABLE public.fresh ALTER COLUMN x SET STATISTICS 0;
      ANALYZE public.readings, public.fresh, public.orders, public.customers;
    SQL
  end

  let(:relations) do
    %w[readings fresh orders customers].map { Quaack::Enclave::TableName.new(schema: "public", name: it) }
  end

  # 3g and 3c, then 3e. Returns the redacted SQL and the Result.
  def literal_sets(query)
    sql = redact(query)
    Quaack::Enclave::PlannerStatistics.run(store:, relations:, connection: conn)
    [sql, described_class.run(store:, sql:)]
  end

  def redact(query)
    explain = JSON.parse(conn.exec("EXPLAIN (ANALYZE, VERBOSE, BUFFERS, FORMAT JSON) #{query}").getvalue(0, 0))
    redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(query), explain)
    redacted.store(store)
    redacted.query.sql
  end

  def pg_stats(table, column, field)
    conn.exec_params("SELECT #{field}::text::text[] FROM pg_stats WHERE tablename = $1 AND attname = $2",
                     [table, column]).getvalue(0, 0)&.then { PG::TextDecoder::Array.new.decode(it) }
  end

  def bounds(column) = pg_stats("readings", column, "histogram_bounds")

  def middle(column) = bounds(column)[bounds(column).size / 2]

  def values(result, set) = result.sets.fetch(set).transform_values { it["value"] }

  def types(result, set) = result.sets.fetch(set).transform_values { it["type"] }

  def rows(sql, set)
    bound = Quaack::Enclave::Redaction.binding(sql, set)
    bound.prepare(conn, "quaack_3e")
    bound.execute(conn, "quaack_3e").values
  ensure
    conn.exec("DEALLOCATE ALL")
  end

  describe "equality" do
    it "takes the top MCV for the worst case and the middle histogram bound for the typical value" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k = 12345")

      expect(pg_stats("readings", "k", "most_common_vals").first).to eq("7")
      expect(values(result, "slow")).to eq("$1" => "12345")
      expect(values(result, "worst_case")).to eq("$1" => "7")
      expect(values(result, "typical")).to eq("$1" => middle("k"))
      expect(types(result, "worst_case")).to eq("$1" => "integer")
      expect(result.fallbacks).to eq("worst_case" => {}, "typical" => {})
    end

    it "takes the column's side from either side of the operator" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE 12345 = r.k")

      expect(values(result, "worst_case")).to eq("$1" => "7")
    end

    it "falls back to the slow literal for a set whose statistics the column lacks, and records it" do
      _, result = literal_sets("SELECT o.id FROM public.orders o WHERE o.status = 'returned' AND o.total_cents = 5")
      total_bounds = pg_stats("orders", "total_cents", "histogram_bounds")

      expect(values(result, "worst_case")).to eq("$1" => "delivered", "$2" => "5")
      expect(values(result, "typical")).to eq("$1" => "returned", "$2" => total_bounds[total_bounds.size / 2])
      expect(result.fallbacks).to eq("worst_case" => { "$2" => "no_mcv" }, "typical" => { "$1" => "no_histogram" })
    end
  end

  describe "ranges" do
    it "takes the last bound for < and <=, and the first for > and >=, each selecting the most rows" do
      sql, result = literal_sets("SELECT count(*) FROM public.readings r WHERE r.amount < 20 AND r.amount <= 20 " \
                                 "AND r.amount > 20 AND r.amount >= 20 AND 20 < r.id")
      id_bounds = bounds("id")

      expect(values(result, "worst_case")).to eq("$1" => bounds("amount").last, "$2" => bounds("amount").last,
                                                 "$3" => bounds("amount").first, "$4" => bounds("amount").first,
                                                 "$5" => id_bounds.first)
      # The amount bounds pair up, like BETWEEN. The id bound is alone.
      after = bounds("amount")[(bounds("amount").size / 2) + 1]
      expect(values(result, "typical")).to eq("$1" => after, "$2" => after, "$3" => middle("amount"),
                                              "$4" => middle("amount"), "$5" => middle("id"))
      expect(types(result, "worst_case")).to include("$1" => "numeric", "$5" => "integer")
      expect(rows(sql, result.sets["worst_case"])).to eq([["9998"]])
    end

    it "selects more rows with the worst-case bound than with any other bound" do
      sql, result = literal_sets("SELECT count(*) FROM public.readings r WHERE r.amount > 20")
      counts = bounds("amount").map do |bound|
        rows(sql, "$1" => { "value" => bound, "type" => "numeric" }).first.first.to_i
      end

      expect(rows(sql, result.sets["worst_case"]).first.first.to_i).to eq(counts.max)
      expect(rows(sql, result.sets["typical"]).first.first.to_i).to be < counts.max
    end

    it "treats a lower and an upper bound on one column in the same AND like BETWEEN" do
      sql, result = literal_sets("SELECT count(*) FROM public.orders o " \
                                 "WHERE o.created_at >= '2026-01-05' AND o.created_at < '2026-01-06'")
      created = pg_stats("orders", "created_at", "histogram_bounds")

      expect(values(result, "worst_case")).to eq("$1" => created.first, "$2" => created.last)
      expect(values(result,
                    "typical")).to eq("$1" => created[created.size / 2], "$2" => created[(created.size / 2) + 1])
      # One bucket of a 100-bucket histogram of 20,000 rows.
      expect(rows(sql, result.sets["typical"]).first.first.to_i).to be_within(20).of(200)
      expect(rows(sql, result.sets["worst_case"]).first.first.to_i).to eq(19_999)
    end

    it "pairs the bounds written either way round, and leaves a range under OR alone" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE 10 < r.amount AND 30 >= r.amount " \
                               "AND (r.id > 5 OR r.id < 9)")
      amount = bounds("amount")

      expect(values(result, "typical")).to eq("$1" => amount[amount.size / 2], "$2" => amount[(amount.size / 2) + 1],
                                              "$3" => middle("id"), "$4" => middle("id"))
    end

    it "pairs only a lower and an upper bound on the same column in the same AND" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.amount < 20 AND r.amount <= 30 " \
                               "AND r.id > 50")
      _, apart = literal_sets("SELECT r.id FROM public.readings r WHERE CASE WHEN r.amount > 20 THEN r.amount < 30 END")

      expect(values(result, "typical")).to eq("$1" => middle("amount"), "$2" => middle("amount"), "$3" => middle("id"))
      expect(values(apart, "typical")).to eq("$1" => middle("amount"), "$2" => middle("amount"))
    end

    it "falls back to the slow literal in both sets for a column with no histogram" do
      _, result = literal_sets("SELECT o.id FROM public.orders o WHERE o.status > 'm'")

      expect(values(result, "worst_case")).to eq("$1" => "m")
      expect(result.fallbacks).to eq("worst_case" => { "$1" => "no_histogram" },
                                     "typical" => { "$1" => "no_histogram" })
    end

    it "takes the widest bounds for BETWEEN in the worst case, and the middle bucket for the typical value" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.amount BETWEEN 10 AND 30")
      amount = bounds("amount")

      expect(values(result, "worst_case")).to eq("$1" => amount.first, "$2" => amount.last)
      expect(values(result, "typical")).to eq("$1" => amount[amount.size / 2], "$2" => amount[(amount.size / 2) + 1])
    end
  end

  describe "IN lists" do
    it "keeps the list's length, with the most common values in the worst case" do
      sql, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k IN (1, 2, 5)")
      k = bounds("k")
      start = (k.size / 2) - 1

      expect(values(result, "worst_case")).to eq("$1" => "7", "$2" => "3", "$3" => "11")
      expect(values(result, "typical")).to eq("$1" => k[start], "$2" => k[start + 1], "$3" => k[start + 2])
      expect(rows(sql, result.sets["worst_case"]).size).to eq(6500)
    end

    it "falls back for an element past the end of the MCV list" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k IN (1, 2, 5, 6)")

      expect(values(result, "worst_case")).to eq("$1" => "7", "$2" => "3", "$3" => "11", "$4" => "6")
      expect(result.fallbacks["worst_case"]).to eq("$4" => "no_mcv")
    end

    it "builds an array of the same length for = ANY of an array literal" do
      sql, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k = ANY('{1,2}')")

      expect(values(result, "worst_case")).to eq("$1" => '{"7","3"}')
      expect(rows(sql, result.sets["worst_case"]).size).to eq(6000)
    end

    it "falls back for the whole array when an element can't get a value" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k = ANY('{1,2,5,6}')")

      expect(values(result, "worst_case")).to eq("$1" => "{1,2,5,6}")
      expect(result.fallbacks["worst_case"]).to eq("$1" => "no_mcv")
    end
  end

  describe "the slow literal in all three sets" do
    {
      "LIKE" => ["SELECT r.id FROM public.readings r WHERE r.label LIKE 'v1%'", "operator"],
      "<>" => ["SELECT r.id FROM public.readings r WHERE r.k <> 5", "operator"],
      "NOT IN" => ["SELECT r.id FROM public.readings r WHERE r.k NOT IN (5)", "operator"],
      "a column with no statistics" => ["SELECT f.id FROM public.fresh f WHERE f.x = 2", "no_statistics"],
      "an expression on the column" => ["SELECT r.id FROM public.readings r WHERE lower(r.label) = 'hot'",
                                        "unsupported_shape"],
      "a cast placeholder" => ["SELECT r.id FROM public.readings r WHERE r.k = '5'::integer", "unsupported_shape"],
      "a LIMIT" => ["SELECT r.id FROM public.readings r LIMIT 5", "unsupported_shape"],
      "a subquery's column" => ["SELECT s.k FROM (SELECT r.k FROM public.readings r) s WHERE s.k = 5",
                                "unsupported_shape"]
    }.each do |name, (query, reason)|
      it "for #{name}" do
        sql, result = literal_sets(query)

        expect(result.sets["worst_case"]).to eq(result.sets["slow"])
        expect(result.sets["typical"]).to eq(result.sets["slow"])
        expect(result.fallbacks).to eq("worst_case" => { "$1" => reason }, "typical" => { "$1" => reason })
        rows(sql, result.sets["typical"])
      end
    end

    it "for a placeholder that more than one expression shares" do
      sql, result = literal_sets("SELECT count(*) FROM public.readings r GROUP BY r.k = 5 HAVING r.k = 5")

      expect(sql).to end_with("GROUP BY r.k = $1 HAVING r.k = $1")
      expect(values(result, "worst_case")).to eq("$1" => "5")
      expect(result.fallbacks["worst_case"]).to eq("$1" => "shared_placeholder")
    end

    it "for a statistics value that doesn't read as the placeholder's type" do
      sql, = literal_sets("SELECT r.id FROM public.readings r WHERE r.k = 5")
      statistics = store.read("statistics")
      readings = statistics["tables"].find { it["name"] == "readings" }
      readings["columns"]["k"]["most_common_vals"] = %w[seven 3]
      store.write("statistics", statistics)
      result = described_class.run(store:, sql:)

      expect(values(result, "worst_case")).to eq("$1" => "5")
      expect(result.fallbacks["worst_case"]).to eq("$1" => "type_mismatch")
    end
  end

  describe "binding" do
    it "binds and runs every set on Postgres, with each value typed as the placeholder declares" do
      sql, result = literal_sets(
        "SELECT r.id, r.label FROM public.readings r WHERE r.k = 1 AND r.amount BETWEEN 3 AND 9 " \
        "OR r.k IN (4, 5, 6) OR r.label LIKE 'v%' OR r.label = 'x' ORDER BY r.id LIMIT 10"
      )

      %w[slow worst_case typical].each do |set|
        expect(rows(sql, result.sets[set]).size).to eq(10), set
      end
    end

    it "stores the sets and reads them back" do
      _, result = literal_sets("SELECT r.id FROM public.readings r WHERE r.k = 12345")

      expect(store.read("literal_sets")).to eq(result.sets.merge("fallbacks" => result.fallbacks))
      expect(described_class.load(store)).to eq(result)
    end

    it "binds a boolean column's top MCV as a boolean" do
      sql, result = literal_sets("SELECT count(*) FROM public.readings r WHERE r.flag = true")

      expect(result.sets["worst_case"]).to eq("$1" => { "value" => "f", "type" => "boolean" })
      expect(rows(sql, result.sets["worst_case"])).to eq([["6667"]])
    end

    it "widens an integer placeholder to numeric for a decimal value, so it binds" do
      sql, result = literal_sets("SELECT count(*) FROM public.readings r WHERE r.amount = 20")

      expect(types(result, "typical")).to eq("$1" => "numeric")
      expect(values(result, "typical")).to eq("$1" => middle("amount"))
      expect(rows(sql, result.sets["typical"])).to eq([["1"]])
    end
  end

  it "widens an integer placeholder to bigint for a value past integer's range" do
    sql, result = literal_sets("SELECT count(*) FROM public.readings r WHERE r.big = 5")

    expect(result.sets["typical"]).to eq("$1" => { "value" => bounds("big")[bounds("big").size / 2],
                                                   "type" => "bigint" })
    expect(rows(sql, result.sets["typical"])).to eq([["1"]])
  end

  it "refuses a stored literal_sets entry that isn't one" do
    literal_sets("SELECT r.id FROM public.readings r WHERE r.k = 5")
    store.write("literal_sets", store.read("literal_sets").except("fallbacks"))

    expect { described_class.load(store) }.to raise_error(described_class::Error, "bad_literal_sets")
  end

  describe "the trust boundary" do
    let(:sentinels) { LeakCheck::Sentinels.new }

    it "keeps planted values out of the result's inspect and to_s" do
      planted = LeakCheck::Fixture.plant(conn, sentinels)
      _, result = literal_sets(planted.query)

      # The sentinel number repeats, so it's total_cents's top MCV.
      expect(values(result, "worst_case").values).to include(sentinels.number.to_s)
      expect(values(result, "slow").values).to include(sentinels.text)
      expect_no_leaks(sentinels, stdout: [result.inspect, result.to_s, PP.pp(result, +"")].join("\n"))
    end

    it "raises bad_statistics, without the value, for a stored statistics entry it can't read" do
      planted = LeakCheck::Fixture.plant(conn, sentinels)
      sql, = literal_sets(planted.query)
      statistics = store.read("statistics")
      orders = statistics["tables"].find { it["name"] == "orders" }
      orders["columns"]["total_cents"]["most_common_vals"] = sentinels.text
      store.write("statistics", statistics)

      error = begin
        described_class.run(store:, sql:)
      rescue described_class::Error => e
        e
      end
      expect([error&.message, error&.rule, error&.cause]).to eq(["bad_statistics", "bad_statistics", nil])
      expect_no_leaks(sentinels, objects: { error: })
    end

    it "refuses SQL with a placeholder the map doesn't have" do
      literal_sets("SELECT r.id FROM public.readings r WHERE r.k = 5")

      expect { described_class.run(store:, sql: "SELECT r.id FROM public.readings r WHERE r.k = $2") }
        .to raise_error(Quaack::Enclave::Redaction::Error, "unknown_placeholder")
    end
  end
end
