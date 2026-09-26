# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/pii_classification"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/config"
require "quaack/enclave/store"

# README 3f against real pg_stats: 3c (PlannerStatistics.run) stores the
# statistics, and this classifies every column of the query's tables and
# works out what of them may leave.
#
# public.accounts, analyzed, 3000 rows (ANALYZE reads them all):
# - id: bigint, unique. Many distinct values, but not text, so not PII.
# - status: text, four values. Low-cardinality, so its MCV values may leave.
# - email: text, unique. High-cardinality text, so PII by the heuristic.
# - country: text, three values, but on the configured list, so PII, and not
#   low-cardinality.
# - nickname: text, added after ANALYZE, so it has no pg_stats row and no
#   distinct count. Unknown text fails closed: PII.
RSpec.describe Quaack::Enclave::PiiClassification do
  let(:db) { test_database }
  let(:conn) { db.connection }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }
  let(:accounts) { table("public", "accounts") }
  let(:config) { Quaack::Enclave::Config.new({ "pii_columns" => ["*.accounts.country"] }) }

  around do |example|
    Dir.mktmpdir("quaack-pii-classification") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE accounts (id bigint PRIMARY KEY, status text NOT NULL, email text NOT NULL, country text);
      INSERT INTO accounts
      SELECT i, (ARRAY['active', 'active', 'active', 'trial', 'closed', 'banned'])[1 + i % 6],
             'user' || i || '@example.com', (ARRAY['NZ', 'CA', 'FR'])[1 + i % 3]
      FROM generate_series(1, 3000) AS i;
      ANALYZE accounts;
      ALTER TABLE accounts ADD COLUMN nickname text;
    SQL
  end

  def table(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  def classify(tables = [accounts], with: config)
    Quaack::Enclave::PlannerStatistics.run(store:, relations: tables, connection: conn)
    described_class.run(store:, config: with)
  end

  def classes(result, table_name = accounts)
    result.columns.select { it.table == table_name }.to_h { [it.name, [it.pii, it.low_cardinality]] }
  end

  def outbound(result, table_name, column)
    tables = result.outbound_statistics["tables"]
    tables.find { it["schema"] == table_name.schema && it["name"] == table_name.name }["columns"]
          .find { it["name"] == column }
  end

  describe "the classification" do
    it "classes each column as PII or not, and as low-cardinality or not" do
      expect(classes(classify)).to eq(
        "id" => [false, false], "status" => [false, true], "email" => [true, false],
        "country" => [true, false], "nickname" => [true, false]
      )
    end

    it "gives Dedupe the low-cardinality columns, as [TableName, column] pairs" do
      expect(classify.low_cardinality).to eq([[accounts, "status"]])
    end

    # 49 and 50 distinct values: n_distinct is the count itself. 40 rows,
    # each different: n_distinct is -1, a fraction of the rows, so the count
    # is 40, as 5a-1 counts. That's under 50, so it isn't PII, but a negative
    # n_distinct means the values don't repeat much, so it isn't
    # low-cardinality either. A column of only NULLs has n_distinct 0, and a
    # table never analyzed has no pg_stats rows, so neither has a count: a
    # text column is PII, and a number column is neither.
    it "draws the line at 50 distinct values, counting them the way 5a-1 does" do
      conn.exec(<<~SQL)
        CREATE TABLE edges (under text, at text, under_n int, at_n int, nothing text);
        INSERT INTO edges SELECT 'v' || i % 49, 'v' || i % 50, i % 49, i % 50, NULL FROM generate_series(1, 5000) AS i;
        CREATE TABLE small (code text);
        INSERT INTO small SELECT 'c' || i FROM generate_series(1, 40) AS i;
        CREATE TABLE fresh (note text, n int);
        INSERT INTO fresh VALUES ('a', 1);
        ANALYZE edges, small;
      SQL
      edges, small, fresh = %w[edges small fresh].map { table("public", it) }
      result = classify([edges, small, fresh])

      expect(classes(result, edges)).to eq("under" => [false, true], "at" => [true, false],
                                           "under_n" => [false, true], "at_n" => [false, false],
                                           "nothing" => [true, false])
      expect(store.read("statistics")["tables"][1]["columns"]["code"]["n_distinct"]).to eq(-1.0)
      expect(classes(result, small)).to eq("code" => [false, false])
      expect(classes(result, fresh)).to eq("note" => [true, false], "n" => [false, false])
    end

    it "moves the line to the configured threshold" do
      result = classify(with: Quaack::Enclave::Config.new({ "cardinality_threshold" => 4 }))

      expect(classes(result).slice("status", "country")).to eq("status" => [true, false], "country" => [false, true])
    end

    it "stores the classification and reads it back as the same result" do
      result = classify

      expect(store.read("classification")["columns"]).to include(
        { "schema" => "public", "table" => "accounts", "column" => "email", "pii" => true, "low_cardinality" => false }
      )
      expect(described_class.load(store)).to eq(result)
    end
  end

  describe "what may leave" do
    it "sends n_distinct, null_frac, and correlation for every analyzed column, PII or not" do
      result = classify
      rows = conn.exec(<<~SQL).values.to_h { |name, *scalars| [name, scalars.map { it && Float(it) }] }
        SELECT attname, n_distinct, null_frac, correlation FROM pg_stats WHERE tablename = 'accounts'
      SQL

      %w[id status email country].each do |column|
        expect(outbound(result, accounts, column).values_at("n_distinct", "null_frac", "correlation"))
          .to eq(rows.fetch(column))
      end
      expect(outbound(result, accounts, "nickname"))
        .to eq({ "name" => "nickname", "n_distinct" => nil, "null_frac" => nil, "correlation" => nil,
                 "most_common_freqs" => nil, "most_common_vals" => nil })
    end

    it "sends a low-cardinality column's MCV values and frequencies" do
      status = outbound(classify, accounts, "status")

      expect(status["most_common_vals"]).to contain_exactly("active", "trial", "closed", "banned")
      expect(status["most_common_vals"].first).to eq("active")
      expect(status["most_common_freqs"].sum).to be_within(0.001).of(1.0)
    end

    it "withholds a PII column's frequencies and values, even when it has few values" do
      country = outbound(classify, accounts, "country")
      stored = store.read("statistics")["tables"].first["columns"]["country"]

      expect(stored["most_common_vals"]).to contain_exactly("NZ", "CA", "FR")
      expect(country.values_at("most_common_freqs", "most_common_vals")).to eq([nil, nil])
    end

    # A 40-row table of people: one email shared by 10 rows (a family
    # address, say), the rest unique. Under 50 distinct values, but most of
    # them are one person's own, so n_distinct is negative and nothing but
    # the frequencies leaves.
    it "sends no values from a small table's column whose values mostly don't repeat" do
      s = LeakCheck::Sentinels.new
      conn.exec(<<~SQL)
        CREATE TABLE people (email text);
        INSERT INTO people SELECT CASE WHEN i <= 10 THEN '#{s.text}' ELSE 'p' || i || '@example.com' END
        FROM generate_series(1, 40) AS i;
        ANALYZE people;
      SQL
      people = table("public", "people")
      result = classify([people])
      stored = store.read("statistics")["tables"].first["columns"]["email"]

      expect(stored["n_distinct"]).to be_negative
      expect(stored["most_common_vals"]).to eq([s.text])
      expect(classes(result, people)).to eq("email" => [false, false])
      expect(outbound(result, people, "email").values_at("most_common_freqs", "most_common_vals")).to eq([[0.25], nil])
      expect(result.low_cardinality).to eq([])
    end

    # accounts.id has no MCV list, since every value is unique, so this
    # uses a number column with repeats but 50 or more distinct values.
    it "sends a column's frequencies but not its values when it has many values and isn't PII" do
      conn.exec(<<~SQL)
        CREATE TABLE scores (points int);
        INSERT INTO scores SELECT CASE WHEN i % 4 = 0 THEN 7 ELSE i % 500 END FROM generate_series(1, 5000) AS i;
        ANALYZE scores;
      SQL
      scores = table("public", "scores")
      points = outbound(classify([scores]), scores, "points")

      expect(store.read("statistics")["tables"].first["columns"]["points"]["most_common_vals"]).to include("7")
      expect(points["most_common_freqs"]).to include(be_within(0.01).of(0.25))
      expect(points["most_common_vals"]).to be_nil
    end

    it "never sends histogram bounds" do
      result = classify
      stored = store.read("statistics")["tables"].first["columns"]

      expect(stored["email"]["histogram_bounds"]).not_to be_nil
      expect(result.outbound_statistics["tables"].first["columns"].flat_map(&:keys).uniq)
        .to eq(%w[name n_distinct null_frac correlation most_common_freqs most_common_vals])
    end

    it "stores what may leave, and it's only plain data" do
      result = classify

      expect(store.read("classification")["outbound_statistics"]).to eq(result.outbound_statistics)
      expect(JSON.parse(JSON.generate(result.outbound_statistics))).to eq(result.outbound_statistics)
    end
  end

  describe "the trust boundary" do
    let(:sentinels) { LeakCheck::Sentinels.new }

    # The fixture puts the text sentinel in customers.name's MCVs (a PII
    # column by the heuristic), the LIKE prefix in customers.email's
    # histogram, the number in orders.total_cents's MCVs and the date in
    # orders.created_at's (many values, not text), and the word in
    # orders.status's MCVs (low-cardinality).
    it "sends none of the planted PII or high-cardinality values, and does send the low-cardinality ones" do
      LeakCheck::Fixture.plant(conn, sentinels)
      customers, orders = %w[customers orders].map { table("public", it) }
      result = classify([customers, orders], with: Quaack::Enclave::Config.new({}))
      stored = store.read("statistics")["tables"].to_h { [it["name"], it["columns"]] }

      # The exposure is real: every sentinel is in the stored statistics.
      expect(stored["customers"]["name"]["most_common_vals"]).to include(sentinels.text)
      expect(stored["customers"]["email"]["histogram_bounds"]).to include(start_with(sentinels.like_prefix))
      expect(stored["orders"]["total_cents"]["most_common_vals"]).to include(sentinels.number.to_s)
      expect(stored["orders"]["created_at"]["most_common_vals"]).to include(start_with(sentinels.date.iso8601))
      expect(stored["orders"]["status"]["most_common_vals"]).to include(sentinels.word)

      LeakCheck.check_scanner!(sentinels)
      found = LeakCheck.findings(sentinels, objects: { outbound: result.outbound_statistics })
      expect(found.map(&:sentinel).uniq).to eq([:word])
      expect(outbound(result, orders, "status")["most_common_vals"]).to include(sentinels.word)
    end
  end
end
