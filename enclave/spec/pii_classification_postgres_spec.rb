# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/dedupe"
require "quaack/enclave/pii_classification"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/config"
require "quaack/enclave/store"

# DESIGN.md's classify against real pg_stats: statistics (PlannerStatistics.run) stores the
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
    # is 40, as index-from-query counts. That's under 50, so it isn't PII, but a negative
    # n_distinct means the values don't repeat much, so it isn't
    # low-cardinality either. A column of only NULLs has n_distinct 0, and a
    # table never analyzed has no pg_stats rows, so neither has a count: a
    # text column is PII, and a number column is neither.
    it "draws the line at 50 distinct values, counting them the way index-from-query does" do
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

    # statistics always lists each table's sendable columns. Without the
    # list, classify can't tell which columns' values may leave, so it
    # fails, and stores nothing, rather than guessing. An entry an older
    # quaacks stored, with structured_columns instead, fails the same way.
    it "fails on a statistics entry without the sendable columns" do
      Quaack::Enclave::PlannerStatistics.run(store:, relations: [accounts], connection: conn)
      data = store.read("statistics")
      data["tables"].each { it.delete("sendable_columns") }
      store.write("statistics", data)

      expect { described_class.run(store:, config:) }.to raise_error(KeyError, /sendable_columns/)
      expect(store.entry?("classification")).to be(false)
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
      expect(stored["customers"]["preferences"]["most_common_vals"]).to include(sentinels.json)

      LeakCheck.check_scanner!(sentinels)
      found = LeakCheck.findings(sentinels, objects: { outbound: result.outbound_statistics })
      expect(found.map(&:sentinel).uniq).to eq([:word])
      expect(outbound(result, orders, "status")["most_common_vals"]).to include(sentinels.word)
    end
  end

  # DESIGN.md's classify: json, jsonb, and array columns, and a domain over
  # one, are never low-cardinality, however few values they hold, so their
  # MCV values never leave. Their frequencies follow the usual rules. An
  # expression index or statistics object over one follows from its base
  # columns. Each column holds two values, one of them its own sentinel set's.
  # json has no equality operator, so ANALYZE keeps no MCV list for it, but
  # an expression index over it does.
  describe "json, jsonb, and array columns" do
    let(:sets) { %w[j jb tags nums dp].to_h { [it, LeakCheck::Sentinels.new] } }
    let(:docs) { table("public", "docs") }

    before do
      conn.exec(<<~SQL)
        CREATE DOMAIN prefs AS jsonb;
        CREATE TABLE docs (kind text, j json, jb jsonb, tags text[], nums int[], dp prefs);
        INSERT INTO docs
        SELECT CASE WHEN i % 2 = 0 THEN 'odd' ELSE 'even' END,
               CASE WHEN i % 2 = 0 THEN '#{sets["j"].json}' ELSE '{}' END::json,
               CASE WHEN i % 2 = 0 THEN '#{sets["jb"].json}' ELSE '{}' END::jsonb,
               CASE WHEN i % 2 = 0 THEN ARRAY['#{sets["tags"].text}'] ELSE ARRAY['plain'] END,
               CASE WHEN i % 2 = 0 THEN ARRAY[#{sets["nums"].number}] ELSE ARRAY[1] END,
               CASE WHEN i % 2 = 0 THEN '#{sets["dp"].json}' ELSE '{}' END::prefs
        FROM generate_series(1, 3000) AS i;
        CREATE INDEX docs_j_note ON docs ((j ->> 'note'));
        CREATE INDEX docs_jb_note ON docs ((jb ->> 'note'));
        CREATE INDEX docs_tag ON docs ((tags[1]));
        CREATE STATISTICS docs_jb_ext (mcv) ON kind, jb FROM docs;
        CREATE STATISTICS docs_note_ext (mcv) ON kind, (jb ->> 'note') FROM docs;
        ANALYZE docs;
      SQL
    end

    def docs_result = classify([docs], with: Quaack::Enclave::Config.new({}))

    def stored_docs = store.read("statistics")["tables"].first

    def outbound_docs(res) = res.outbound_statistics["tables"].first

    it "classes them as neither PII nor low-cardinality, and sends their frequencies but not their values" do
      res = docs_result

      expect(classes(res, docs)).to eq("kind" => [false, true], "j" => [false, false], "jb" => [false, false],
                                       "tags" => [false, false], "nums" => [false, false], "dp" => [false, false])
      expect(res.low_cardinality).to eq([[docs, "kind"]])
      %w[jb tags nums dp].each do |column|
        expect(stored_docs["columns"][column]["n_distinct"]).to eq(2.0)
        expect(outbound(res, docs, column)["most_common_freqs"].sum).to be_within(0.001).of(1.0)
        expect(outbound(res, docs, column)["most_common_vals"]).to be_nil
      end
    end

    it "sends an expression index's or statistics object's frequencies over one, but not its values" do
      res = docs_result
      indexes = outbound_docs(res)["indexes"].to_h { [it["name"], it["columns"].first] }
      extended = outbound_docs(res)["extended_statistics"].to_h { [it["name"], it] }

      %w[docs_j_note docs_jb_note docs_tag].each do |name|
        expect(indexes[name]["most_common_freqs"]).to include(be_within(0.01).of(0.5))
        expect(indexes[name]["most_common_vals"]).to be_nil
      end
      %w[docs_jb_ext docs_note_ext].each do |name|
        expect(extended[name]["most_common_freqs"].sum).to be_within(0.001).of(1.0)
        expect(extended[name].values_at("most_common_vals", "most_common_val_nulls")).to eq([nil, nil])
      end
    end

    it "sends none of their values" do
      res = docs_result
      stored = JSON.generate(stored_docs)

      # The exposure is real: every sentinel is in the stored statistics,
      # json's through its expression index.
      sets.each_value { expect(LeakCheck.findings(it, objects: { stored: })).not_to be_empty }
      expect(stored_docs["columns"]["j"]["most_common_vals"]).to be_nil

      sets.each_value do |set|
        LeakCheck.check_scanner!(set)
        expect(LeakCheck.findings(set, objects: { outbound: res.outbound_statistics })).to eq([])
      end
    end
  end

  # DESIGN.md's classify: hstore, xml, tsvector, tsquery, composite, range,
  # and multirange columns, and a domain over one, are structured too, so
  # they're never low-cardinality and their MCV values never leave. Each
  # column holds two values, one of them its own sentinel set's. ANALYZE
  # keeps no MCV list for xml, which has no equality operator, or for
  # tsvector, ranges, and multiranges, which have their own statistics, but
  # an expression index over one does.
  describe "other structured columns" do
    let(:sets) { %w[h x tv tq c r mr dh].to_h { [it, LeakCheck::Sentinels.new] } }
    let(:things) { table("public", "things") }

    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA ext;
        CREATE EXTENSION hstore SCHEMA ext;
        CREATE TYPE pair AS (label text, n int);
        CREATE DOMAIN tag_map AS ext.hstore;
        CREATE TABLE things (kind text, h ext.hstore, x xml, tv tsvector, tq tsquery, c pair, r int4range,
                             mr int4multirange, dh tag_map);
        INSERT INTO things
        SELECT CASE WHEN i % 2 = 0 THEN 'odd' ELSE 'even' END,
               CASE WHEN i % 2 = 0 THEN ext.hstore('note', '#{sets["h"].text}') ELSE ''::ext.hstore END,
               CASE WHEN i % 2 = 0 THEN '<n>#{sets["x"].text}</n>' ELSE '<n/>' END::xml,
               CASE WHEN i % 2 = 0 THEN to_tsvector('simple', '#{sets["tv"].word}') ELSE ''::tsvector END,
               CASE WHEN i % 2 = 0 THEN '#{sets["tq"].word}' ELSE 'plain' END::tsquery,
               CASE WHEN i % 2 = 0 THEN ROW('#{sets["c"].text}', 1)::pair ELSE ROW('plain', 1)::pair END,
               CASE WHEN i % 2 = 0 THEN int4range(#{sets["r"].number}, #{sets["r"].number + 1})
                    ELSE int4range(1, 2) END,
               CASE WHEN i % 2 = 0 THEN int4multirange(int4range(#{sets["mr"].number}, #{sets["mr"].number + 1}))
                    ELSE int4multirange(int4range(1, 2)) END,
               CASE WHEN i % 2 = 0 THEN ext.hstore('note', '#{sets["dh"].text}') ELSE ''::ext.hstore END::tag_map
        FROM generate_series(1, 3000) AS i;
        CREATE INDEX things_x_text ON things ((x::text));
        CREATE INDEX things_tv_text ON things ((tv::text));
        CREATE INDEX things_r_lower ON things ((lower(r)));
        CREATE INDEX things_mr_lower ON things ((lower(mr)));
        CREATE INDEX things_c_label ON things (((c).label));
        CREATE STATISTICS things_h_ext (mcv) ON kind, h FROM things;
        ANALYZE things;
      SQL
    end

    def things_result = classify([things], with: Quaack::Enclave::Config.new({}))

    def stored_things = store.read("statistics")["tables"].first

    def outbound_things(res) = res.outbound_statistics["tables"].first

    it "classes them as neither PII nor low-cardinality, and sends their frequencies but not their values" do
      res = things_result
      expect(classes(res, things)).to eq(%w[h x tv tq c r mr dh].to_h { [it, [false, false]] }
                                           .merge("kind" => [false, true]))
      expect(res.low_cardinality).to eq([[things, "kind"]])
      %w[h tq c dh].each do |column|
        expect(stored_things["columns"][column]["most_common_vals"].size).to eq(2)
        expect(outbound(res, things, column)["most_common_freqs"].sum).to be_within(0.001).of(1.0)
        expect(outbound(res, things, column)["most_common_vals"]).to be_nil
      end
    end

    it "sends an expression index's or statistics object's frequencies over one, but not its values" do
      res = things_result
      indexes = outbound_things(res)["indexes"].to_h { [it["name"], it["columns"].first] }
      extended = outbound_things(res)["extended_statistics"].first

      %w[things_x_text things_tv_text things_r_lower things_mr_lower things_c_label].each do |name|
        expect(indexes[name]["most_common_freqs"]).to include(be_within(0.01).of(0.5))
        expect(indexes[name]["most_common_vals"]).to be_nil
      end
      expect(extended["most_common_freqs"].sum).to be_within(0.001).of(1.0)
      expect(extended.values_at("most_common_vals", "most_common_val_nulls")).to eq([nil, nil])
    end

    it "sends none of their values" do
      res = things_result
      stored = JSON.generate(stored_things)

      # The exposure is real: every sentinel is in the stored statistics,
      # xml's, tsvector's, and the ranges' through their expression indexes.
      sets.each_value { expect(LeakCheck.findings(it, objects: { stored: })).not_to be_empty }
      %w[x tv r mr].each { expect(stored_things["columns"][it]["most_common_vals"]).to be_nil }

      sets.each_value do |set|
        LeakCheck.check_scanner!(set)
        expect(LeakCheck.findings(set, objects: { outbound: res.outbound_statistics })).to eq([])
      end
    end
  end

  # DESIGN.md's classify: only text-like columns and the allowlisted types
  # (numbers, money, oid, boolean, the date and time types, uuid, enums, and
  # domains over them) may be low-cardinality. Every other type is withheld
  # like json: bytea, which can hold text, the geometric types, which can
  # hold a place, the network types, which can name a person's device or
  # address, bit strings, and the rest, and a domain over one. Each column
  # holds two values, one of them planted. The set's needles are the planted
  # values as pg_stats prints them: bytea as hex, bit strings as binary
  # digits. point has no equality operator, so ANALYZE keeps no MCV list for
  # it, but an expression index over it does.
  describe "columns of a type whose values may not leave" do
    let(:token) { -> { LeakCheck::Sentinels.claim { "sentinel#{SecureRandom.hex(6)}" } } }
    let(:bytes) { %w[b blob].to_h { [it, "#{token.call}-#{it}"] } }
    let(:planted) do
      octets = Array.new(3) { rand(100..255) }
      { b: bytes["b"].unpack1("H*"), blob: bytes["blob"].unpack1("H*"),
        p: LeakCheck::Sentinels.claim { rand(100_000_000..999_999_999) }.to_s,
        ip: "10.#{octets.join(".")}",
        mac: ["0a", *Array.new(5) { rand(256).to_s(16).rjust(2, "0") }].join(":"),
        bits: LeakCheck::Sentinels.claim { rand((2**31)...(2**32)) }.to_s(2) }
    end
    let(:set) { LeakCheck::Sentinels.new(extra: planted) }
    let(:gear) { table("public", "gear") }

    before do
      conn.exec(<<~SQL)
        CREATE DOMAIN blob AS bytea;
        CREATE TABLE gear (kind text, b bytea, p point, ip inet, mac macaddr, bits bit(32), blob blob);
        INSERT INTO gear
        SELECT CASE WHEN i % 2 = 0 THEN 'odd' ELSE 'even' END,
               CASE WHEN i % 2 = 0 THEN convert_to('#{bytes["b"]}', 'UTF8') ELSE '\\x00' END,
               CASE WHEN i % 2 = 0 THEN point(#{planted[:p]}, 1) ELSE point(0, 0) END,
               CASE WHEN i % 2 = 0 THEN '#{planted[:ip]}' ELSE '127.0.0.1' END::inet,
               CASE WHEN i % 2 = 0 THEN '#{planted[:mac]}' ELSE '00:00:00:00:00:00' END::macaddr,
               CASE WHEN i % 2 = 0 THEN B'#{planted[:bits]}' ELSE B'#{"0" * 32}' END,
               CASE WHEN i % 2 = 0 THEN convert_to('#{bytes["blob"]}', 'UTF8') ELSE '\\x00' END::blob
        FROM generate_series(1, 3000) AS i;
        CREATE INDEX gear_p_x ON gear ((p[0]));
        CREATE STATISTICS gear_b_ext (mcv) ON kind, b FROM gear;
        ANALYZE gear;
      SQL
    end

    def gear_result = classify([gear], with: Quaack::Enclave::Config.new({}))

    def stored_gear = store.read("statistics")["tables"].first

    it "classes them as neither PII nor low-cardinality, and sends their frequencies but not their values" do
      res = gear_result

      expect(classes(res, gear)).to eq(%w[b p ip mac bits blob].to_h { [it, [false, false]] }
                                         .merge("kind" => [false, true]))
      expect(res.low_cardinality).to eq([[gear, "kind"]])
      %w[b ip mac bits blob].each do |column|
        expect(stored_gear["columns"][column]["most_common_vals"].size).to eq(2)
        expect(outbound(res, gear, column)["most_common_freqs"].sum).to be_within(0.001).of(1.0)
        expect(outbound(res, gear, column)["most_common_vals"]).to be_nil
      end
    end

    it "sends an expression index's or statistics object's frequencies over one, but not its values" do
      tables = gear_result.outbound_statistics["tables"].first
      index = tables["indexes"].find { it["name"] == "gear_p_x" }["columns"].first
      extended = tables["extended_statistics"].first

      expect(index["most_common_freqs"]).to include(be_within(0.01).of(0.5))
      expect(index["most_common_vals"]).to be_nil
      expect(extended["most_common_freqs"].sum).to be_within(0.001).of(1.0)
      expect(extended.values_at("most_common_vals", "most_common_val_nulls")).to eq([nil, nil])
    end

    it "sends none of their values" do
      res = gear_result

      # The exposure is real: every planted value is in the stored
      # statistics, point's through its expression index.
      found = LeakCheck.findings(set, objects: { stored: JSON.generate(stored_gear) }).map(&:sentinel)
      expect(found.uniq.sort).to eq(planted.keys.sort)
      expect(stored_gear["columns"]["p"]["most_common_vals"]).to be_nil

      expect_no_leaks(set, objects: { outbound: res.outbound_statistics })
    end

    # DESIGN.md's index-dedupe fails closed on them: since none is
    # low-cardinality, however few values it holds, dedupe drops a partial
    # candidate whose predicate compares one with a constant. A predicate
    # with no constant, such as ip IS NULL, still passes, as on any column.
    it "makes dedupe drop a partial candidate whose predicate compares one with a constant" do
      res = gear_result
      search = Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::PlannerStatistics.load(store).statistics,
                                           low_cardinality: res.low_cardinality)
      partial = lambda do |predicate|
        Quaack::Enclave::IndexCandidate.new(table: gear, key: ["kind"], predicate:, sources: [:llm])
      end
      on_ip, on_kind, ip_null = ["ip = '127.0.0.1'", "kind = 'odd'", "ip IS NULL"].map(&partial)

      expect(search.filter([on_ip, on_kind, ip_null])).to eq([on_kind, ip_null])
      expect(search.drops.map { [it.candidate, it.reason] }).to eq([[on_ip, :partial_not_low_cardinality]])
    end
  end

  # DESIGN.md's classify: the allowlisted types, an enum, and a domain over
  # one at any depth, are still low-cardinality when they hold few values
  # that repeat, so their MCV values leave.
  describe "columns of an allowlisted type" do
    let(:ledger) { table("public", "ledger") }

    before do
      conn.exec(<<~SQL)
        CREATE TYPE mood AS ENUM ('sad', 'fine', 'glad');
        CREATE DOMAIN qty AS int;
        CREATE DOMAIN calm AS mood;
        CREATE DOMAIN deep_calm AS calm;
        CREATE TABLE ledger (n int, big bigint, amount numeric(6, 2), price money, ok boolean, day date,
                             at timestamptz, wait interval, ref uuid, m mood, q qty, dm deep_calm);
        INSERT INTO ledger
        SELECT i % 3, i % 3 + 10000000000, i % 3 + 0.5, (i % 3)::numeric::money, i % 3 = 0,
               date '2024-01-01' + i % 3, timestamptz '2024-01-01 00:00Z' + (i % 3) * interval '1 hour',
               (i % 3) * interval '1 day', ('00000000-0000-0000-0000-00000000000' || i % 3)::uuid,
               (ARRAY['sad', 'fine', 'glad']::mood[])[1 + i % 3], i % 3,
               (ARRAY['sad', 'fine', 'glad']::mood[])[1 + i % 3]
        FROM generate_series(1, 3000) AS i;
        ANALYZE ledger;
      SQL
    end

    it "classes them as low-cardinality, and sends their values" do
      res = classify([ledger], with: Quaack::Enclave::Config.new({}))
      names = %w[n big amount price ok day at wait ref m q dm]
      stored = store.read("statistics")["tables"].first["columns"]

      expect(classes(res, ledger)).to eq(names.to_h { [it, [false, true]] })
      names.each do |column|
        expect(stored[column]["most_common_vals"]).not_to be_empty
        expect(outbound(res, ledger, column)["most_common_vals"]).to eq(stored[column]["most_common_vals"])
      end
    end
  end

  # DESIGN.md's classify: an expression index's pg_stats rows and a CREATE STATISTICS
  # object's MCV list are classified by the base columns they read. One that
  # reads any PII column is PII, so none of its MCV data leaves. Its values
  # leave only when every base column is low-cardinality.
  describe "expression indexes and extended statistics" do
    let(:sentinels) { LeakCheck::Sentinels.new }
    let(:tags) { table("public", "tags") }

    before do
      conn.exec(<<~SQL)
        CREATE TABLE tags (id bigint, kind text, secret text);
        INSERT INTO tags SELECT i, (ARRAY['Red', 'Blue'])[1 + i % 2],
               CASE WHEN i % 2 = 0 THEN '#{sentinels.text}' ELSE 'other' END FROM generate_series(1, 3000) AS i;
        CREATE INDEX tags_kind ON tags (lower(kind));
        CREATE INDEX tags_secret ON tags (lower(secret));
        CREATE INDEX tags_mixed ON tags ((kind || (id % 100)::text));
        CREATE STATISTICS tags_kind_ext (mcv) ON kind, (id % 100) FROM tags;
        CREATE STATISTICS tags_secret_ext (mcv) ON kind, secret FROM tags;
        CREATE STATISTICS tags_low_ext (mcv) ON kind, lower(kind) FROM tags;
        ANALYZE tags;
      SQL
    end

    def tags_result = classify([tags], with: Quaack::Enclave::Config.new({ "pii_columns" => ["*.tags.secret"] }))

    def outbound_table(res) = res.outbound_statistics["tables"].first

    def index(res, name) = outbound_table(res)["indexes"].find { it["name"] == name }["columns"].first

    def ext(res, name) = outbound_table(res)["extended_statistics"].find { it["name"] == name }

    it "sends an expression index's MCVs, classified by its base columns" do
      res = tags_result

      expect(index(res, "tags_kind")["most_common_vals"]).to contain_exactly("red", "blue")
      expect(index(res, "tags_secret").values_at("most_common_freqs", "most_common_vals")).to eq([nil, nil])
      expect(index(res, "tags_secret")["n_distinct"]).to eq(2.0)
      expect(index(res, "tags_mixed")["most_common_vals"]).to be_nil
      expect(index(res, "tags_mixed")["most_common_freqs"]).not_to be_nil
    end

    it "sends an extended statistics object's MCVs, classified by its base columns" do
      res = tags_result

      expect(ext(res, "tags_low_ext")["most_common_vals"]).to contain_exactly(%w[Blue blue], %w[Red red])
      expect(ext(res, "tags_kind_ext")["most_common_vals"]).to be_nil
      expect(ext(res, "tags_kind_ext")["most_common_freqs"].sum).to be_within(0.001).of(1.0)
      expect(ext(res, "tags_secret_ext").values_at("most_common_vals", "most_common_freqs",
                                                   "most_common_base_freqs")).to eq([nil, nil, nil])
    end

    it "sends none of a PII column's values through an expression" do
      res = tags_result
      stored = store.read("statistics")["tables"].first
      expect(stored["extended_statistics"].find { it["name"] == "tags_secret_ext" }["most_common_vals"].flatten)
        .to include(sentinels.text)

      LeakCheck.check_scanner!(sentinels)
      found = LeakCheck.findings(sentinels, objects: { outbound: res.outbound_statistics })
      expect(found).to eq([])
    end
  end
end
