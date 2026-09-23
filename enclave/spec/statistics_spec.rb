# frozen_string_literal: true

require "pp"
require "quaack/enclave/statistics"
require "quaack/enclave/index_candidate"

RSpec.describe "the statistics input" do
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }

  def column(n_distinct:, null_frac: 0.0, correlation: nil)
    Quaack::Enclave::ColumnStatistics.new(n_distinct:, null_frac:, correlation:)
  end

  def table(columns, reltuples: 1000.0, name: orders, column_names: columns.keys, indexes: {})
    Quaack::Enclave::TableStatistics.new(name:, reltuples:, columns:, column_names:, indexes:)
  end

  def index_on(table_name, key)
    Quaack::Enclave::IndexCandidate.new(table: table_name, key:, sources: [:existing])
  end

  describe Quaack::Enclave::TableName do
    it "compares by value, so it works as a hash key" do
      same = described_class.new(schema: "public", name: "orders")

      expect({ orders => 1 }[same]).to eq(1)
    end

    it "freezes its own copies of the parts, leaving the caller's strings alone" do
      schema = +"public"
      table = +"orders"
      name = described_class.new(schema:, name: table)
      schema << "_changed"
      table << "_changed"

      expect([name.schema, name.name]).to eq(%w[public orders])
      expect([name.schema, name.name]).to all(be_frozen)
      expect([schema, table]).to all(satisfy { |s| !s.frozen? })
    end

    it "requires a non-empty schema and name" do
      expect { described_class.new(schema: "", name: "orders") }.to raise_error(ArgumentError, /schema/)
      expect { described_class.new(schema: nil, name: "orders") }.to raise_error(ArgumentError, /schema/)
      expect { described_class.new(schema: "public", name: "") }.to raise_error(ArgumentError, /name/)
    end
  end

  describe Quaack::Enclave::ColumnStatistics do
    def with_mcvs(vals, freqs, **)
      described_class.new(n_distinct: 10.0, null_frac: 0.0, correlation: nil,
                          most_common_vals: vals, most_common_freqs: freqs, **)
    end

    describe "most common values" do
      it "keeps the values and their frequencies, with the frequencies as Floats" do
        stats = with_mcvs(%w[delivered shipped], [0.5, Rational(1, 4)])

        expect(stats.most_common_vals).to eq(%w[delivered shipped])
        expect(stats.most_common_freqs).to eq([0.5, 0.25])
        expect(stats.most_common_freqs).to all(be_a(Float))
      end

      it "leaves both nil when they're omitted, so existing callers keep working" do
        stats = described_class.new(n_distinct: 10.0, null_frac: 0.0, correlation: nil)

        expect([stats.most_common_vals, stats.most_common_freqs]).to eq([nil, nil])
      end

      it "keeps frozen copies, leaving the caller's arrays and strings alone" do
        vals = [+"delivered", +"shipped"]
        freqs = [0.5, 0.25]
        stats = with_mcvs(vals, freqs)
        vals.first << "_changed"
        vals << +"extra"
        freqs << 0.1

        expect(stats.most_common_vals).to eq(%w[delivered shipped])
        expect(stats.most_common_freqs).to eq([0.5, 0.25])
        expect([stats.most_common_vals, stats.most_common_freqs, *stats.most_common_vals]).to all(be_frozen)
        expect([vals, freqs, *vals]).to all(satisfy { |v| !v.frozen? })
      end

      it "requires both or neither" do
        expect { with_mcvs(%w[a], nil) }.to raise_error(ArgumentError, /given together/)
        expect { with_mcvs(nil, [0.5]) }.to raise_error(ArgumentError, /given together/)
      end

      it "requires an Array of Strings and an Array of frequencies" do
        [["a", [0.5]], [[:a], [0.5]], [[nil], [0.5]], [[1], [0.5]]].each do |vals, freqs|
          expect do
            with_mcvs(vals, freqs)
          end.to raise_error(ArgumentError, /most_common_vals must be an Array of Strings/)
        end
        expect { with_mcvs(%w[a], 0.5) }.to raise_error(ArgumentError, /most_common_freqs must be an Array/)
        expect(with_mcvs([""], [0.5]).most_common_vals).to eq([""])
      end

      it "requires one frequency per value" do
        expect { with_mcvs(%w[a b], [0.5]) }.to raise_error(ArgumentError, /2 values but 1 frequenc/)
        expect { with_mcvs(%w[a], [0.5, 0.25]) }.to raise_error(ArgumentError, /1 values but 2 frequenc/)
      end

      it "requires each frequency to be a finite real number from 0 to 1" do
        [1.5, -0.1, Float::NAN, Float::INFINITY, Complex(0.5, 0), "0.5", nil].each do |bad|
          expect { with_mcvs(%w[a], [bad]) }.to raise_error(ArgumentError, /most_common_freqs/), bad.inspect
        end
        expect(with_mcvs(%w[a b], [0, 1]).most_common_freqs).to eq([0.0, 1.0])
      end

      # pg_stats stores frequencies as float4, so a full list can sum to a
      # hair over 1.
      it "requires the frequencies to sum to at most 1, give or take rounding" do
        expect { with_mcvs(%w[a b], [0.6, 0.5]) }.to raise_error(ArgumentError, /sum to more than 1/)
        expect { with_mcvs(%w[a b], [0.6, 0.4 + 2e-6]) }.to raise_error(ArgumentError, /sum to more than 1/)
        expect(with_mcvs(%w[a b], [0.6, 0.4 + 5e-7]).most_common_freqs.sum).to be > 1
      end

      it "gives an MCV's frequency by its exact text, and nil for anything else" do
        stats = with_mcvs(%w[delivered shipped], [0.5, 0.25])

        expect(%w[shipped delivered Shipped other].map { |t| stats.mcv_frequency(t) }).to eq([0.25, 0.5, nil, nil])
        expect(described_class.new(n_distinct: 1.0, null_frac: 0.0, correlation: nil).mcv_frequency("x")).to be_nil
      end
    end
  end

  describe Quaack::Enclave::TableStatistics do
    describe "#distinct_count" do
      it "returns a positive n_distinct as is" do
        expect(table({ "status" => column(n_distinct: 7.0) }).distinct_count("status")).to eq(7.0)
      end

      it "turns a negative n_distinct into its absolute value times reltuples" do
        stats = table({ "email" => column(n_distinct: -0.5), "id" => column(n_distinct: -1.0) }, reltuples: 1000.0)

        expect(stats.distinct_count("email")).to eq(500.0)
        expect(stats.distinct_count("id")).to eq(1000.0)
      end

      it "returns nil when n_distinct is zero, which pg_stats uses for unknown" do
        expect(table({ "x" => column(n_distinct: 0.0) }).distinct_count("x")).to be_nil
      end

      it "returns nil for a negative n_distinct when reltuples is unknown (negative)" do
        expect(table({ "x" => column(n_distinct: -0.5) }, reltuples: -1.0).distinct_count("x")).to be_nil
      end
    end

    describe "#equality_selectivity" do
      it "is the non-null fraction divided by the distinct count" do
        expect(table({ "status" => column(n_distinct: 10.0, null_frac: 0.2) }).equality_selectivity("status"))
          .to be_within(1e-12).of(0.08)
      end

      it "uses the converted distinct count for a negative n_distinct" do
        stats = table({ "email" => column(n_distinct: -0.5, null_frac: 0.5) }, reltuples: 1000.0)

        expect(stats.equality_selectivity("email")).to be_within(1e-12).of(0.001)
      end

      it "returns nil when the distinct count is unknown" do
        expect(table({ "x" => column(n_distinct: 0.0) }).equality_selectivity("x")).to be_nil
      end
    end

    describe "#value_frequency" do
      def status(n_distinct: 10.0, null_frac: 0.0, vals: %w[delivered shipped], freqs: [0.5, 0.2])
        Quaack::Enclave::ColumnStatistics.new(n_distinct:, null_frac:, correlation: nil,
                                              most_common_vals: vals, most_common_freqs: freqs)
      end

      it "returns an MCV's own frequency" do
        stats = table({ "status" => status })

        expect(stats.value_frequency("status", "shipped")).to eq(0.2)
        expect(stats.value_frequency("status", "delivered")).to eq(0.5)
      end

      it "splits what the MCVs and nulls leave evenly among the other distinct values" do
        stats = table({ "status" => status(n_distinct: 10.0, null_frac: 0.1) })

        # (1 - 0.7 - 0.1) / (10 - 2)
        expect(stats.value_frequency("status", "pending")).to be_within(1e-12).of(0.025)
      end

      it "treats a column with no MCV list like one whose MCVs cover nothing" do
        stats = table({ "note" => column(n_distinct: 10.0, null_frac: 0.2) })

        expect(stats.value_frequency("note", "anything")).to be_within(1e-12).of(0.08)
      end

      # Postgres's var_eq_const divides only when more than one other
      # distinct value is left, so it never divides by zero or a negative.
      it "doesn't divide when one other distinct value or fewer is left" do
        [2.0, 2.5, 1.0].each do |n_distinct|
          stats = table({ "status" => status(n_distinct:, null_frac: 0.1, freqs: [0.5, 0.3]) })

          expect(stats.value_frequency("status", "pending")).to be_within(1e-12).of(0.1), n_distinct.to_s
        end
      end

      it "divides as soon as more than one other distinct value is left" do
        [[3.5, 0.1 / 1.5], [4.0, 0.05]].each do |n_distinct, expected|
          stats = table({ "status" => status(n_distinct:, null_frac: 0.1, freqs: [0.5, 0.3]) })

          expect(stats.value_frequency("status", "pending")).to be_within(1e-12).of(expected), n_distinct.to_s
        end
      end

      it "never says a value that isn't an MCV is more common than the least common MCV" do
        stats = table({ "status" => status(n_distinct: 3.0, freqs: [0.5, 0.05]) })

        expect(stats.value_frequency("status", "pending")).to eq(0.05)
      end

      # pg_stats lists MCVs most common first, but this doesn't rely on it.
      it "caps at the least common MCV even when the list isn't sorted" do
        stats = table({ "status" => status(n_distinct: 3.0, freqs: [0.05, 0.5]) })

        expect(stats.value_frequency("status", "pending")).to eq(0.05)
      end

      it "returns 0.0, not a negative number, when the MCVs and nulls cover every row or more" do
        [[[0.6, 0.35], 0.1, 20.0], [[0.6, 0.4 + 5e-7], 0.0, 2.0]].each do |freqs, null_frac, n_distinct|
          stats = table({ "status" => status(n_distinct:, null_frac:, freqs:) })

          expect(stats.value_frequency("status", "pending")).to eq(0.0), freqs.inspect
        end
      end

      it "returns nil for a value that isn't an MCV when the distinct count is unknown or zero" do
        [[0.0, 1000.0], [-0.5, -1.0], [-0.5, 0.0]].each do |n_distinct, reltuples|
          stats = table({ "status" => status(n_distinct:) }, reltuples:)

          expect(stats.value_frequency("status", "pending")).to be_nil, [n_distinct, reltuples].inspect
        end
      end

      it "still returns an MCV's frequency when the distinct count is unknown, as Postgres does" do
        stats = table({ "status" => status(n_distinct: -0.5) }, reltuples: -1.0)

        expect(stats.value_frequency("status", "shipped")).to eq(0.2)
      end

      it "matches MCVs by their exact text, so another spelling of the same value isn't one" do
        stats = table({ "total" => status(vals: %w[1.50 7], freqs: [0.5, 0.2]) })

        expect(stats.value_frequency("total", "1.50")).to eq(0.5)
        # (1 - 0.7) / (10 - 2), not 0.5 or 0.2
        expect(%w[1.5 07 7.0].map { |text| stats.value_frequency("total", text) })
          .to all(be_within(1e-12).of(0.0375))
      end

      it "returns nil for a column the table has but pg_stats has no row for" do
        stats = table({ "status" => status }, column_names: %w[id status])

        expect(stats.value_frequency("id", "1")).to be_nil
      end

      it "raises KeyError for a column the table doesn't have" do
        expect { table({ "status" => status }).value_frequency("nope", "1") }.to raise_error(KeyError, /nope/)
      end
    end

    describe "#value_frequency's literal" do
      it "must be a String" do
        stats = table({ "status" => column(n_distinct: 3.0) })

        [nil, 1, :shipped].each do |bad|
          expect { stats.value_frequency("status", bad) }.to raise_error(ArgumentError, /literal_text must be a String/)
        end
      end
    end

    describe "column lookup" do
      let(:stats) { table({ "status" => column(n_distinct: 3.0, correlation: 0.9) }) }

      it "returns the column's statistics, and correlation can be nil" do
        expect(stats.column("status").correlation).to eq(0.9)
        expect(table({ "x" => column(n_distinct: 3.0) }).column("x").correlation).to be_nil
      end

      it "raises KeyError naming the table and column when the column is missing" do
        expect { stats.column("nope") }.to raise_error(KeyError, /public\.orders.*nope/)
        expect { stats.distinct_count("nope") }.to raise_error(KeyError, /nope/)
      end

      it "answers column? without raising" do
        expect([stats.column?("status"), stats.column?("nope")]).to eq([true, false])
      end
    end

    it "rejects out-of-range statistics" do
      expect { column(n_distinct: -1.5) }.to raise_error(ArgumentError, /n_distinct/)
      expect { column(n_distinct: 1.0, null_frac: 1.5) }.to raise_error(ArgumentError, /null_frac/)
      expect { column(n_distinct: 1.0, null_frac: -0.1) }.to raise_error(ArgumentError, /null_frac/)
      expect { column(n_distinct: 1.0, correlation: 1.5) }.to raise_error(ArgumentError, /correlation/)
      expect { table({}, reltuples: "many") }.to raise_error(ArgumentError, /reltuples/)
    end

    it "rejects Infinity and NaN" do
      [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |bad|
        expect { column(n_distinct: bad) }.to raise_error(ArgumentError, /n_distinct/)
        expect { column(n_distinct: 1.0, null_frac: bad) }.to raise_error(ArgumentError, /null_frac/)
        expect { column(n_distinct: 1.0, correlation: bad) }.to raise_error(ArgumentError, /correlation/)
        expect { table({}, reltuples: bad) }.to raise_error(ArgumentError, /reltuples/)
      end
    end

    it "accepts a correlation anywhere from -1 to 1" do
      expect([-1.0, -0.9, 1.0].map { |c| column(n_distinct: 1.0, correlation: c).correlation }).to eq([-1.0, -0.9, 1.0])
      expect { column(n_distinct: 1.0, correlation: -1.5) }.to raise_error(ArgumentError, /correlation/)
    end

    it "rejects complex numbers with an ArgumentError" do
      expect { column(n_distinct: Complex(1, 2)) }.to raise_error(ArgumentError, /n_distinct/)
      expect { column(n_distinct: 1.0, null_frac: Complex(0.5, 0)) }.to raise_error(ArgumentError, /null_frac/)
      expect { column(n_distinct: 1.0, correlation: Complex(0, 1)) }.to raise_error(ArgumentError, /correlation/)
      expect { table({}, reltuples: Complex(10, 1)) }.to raise_error(ArgumentError, /reltuples/)
    end

    it "stores numbers as Floats, so integer inputs don't do integer division" do
      stats = table({ "status" => column(n_distinct: 7, null_frac: 0, correlation: 1) }, reltuples: 1000)

      expect([stats.reltuples, stats.column("status").n_distinct, stats.column("status").null_frac,
              stats.column("status").correlation]).to all(be_a(Float))
      expect(stats.equality_selectivity("status")).to be_within(1e-12).of(1.0 / 7)
    end

    it "counts no distinct values in an empty table, with no selectivity" do
      stats = table({ "x" => column(n_distinct: -0.5) }, reltuples: 0)

      expect(stats.distinct_count("x")).to eq(0.0)
      expect(stats.equality_selectivity("x")).to be_nil
    end

    it "requires a TableName and ColumnStatistics values" do
      expect { table({}, name: "public.orders") }.to raise_error(ArgumentError, /TableName/)
      expect { table({ "x" => 3.0 }) }.to raise_error(ArgumentError, /ColumnStatistics/)
      expect do
        table({ x: column(n_distinct: 3.0) }, column_names: ["x"])
      end.to raise_error(ArgumentError, /ColumnStatistics/)
    end

    it "keeps its own frozen copy of the columns" do
      columns = { "status" => column(n_distinct: 3.0) }
      stats = table(columns)
      columns["other"] = column(n_distinct: 1.0)

      expect(stats.columns).to be_frozen
      expect(stats.columns.keys).to eq(["status"])
    end

    describe "the full column list" do
      it "keeps every column in attnum order, including ones with no pg_stats row" do
        stats = table({ "status" => column(n_distinct: 3.0) }, column_names: %w[id status note])

        expect(stats.column_names).to eq(%w[id status note])
        expect(stats.column_names).to be_frozen
        expect(stats.column?("id")).to be(false)
      end

      it "freezes its own copy of each name, leaving the caller's strings alone" do
        names = [+"id", +"status"]
        stats = table({}, column_names: names)
        names.each { |n| n << "_changed" }

        expect(stats.column_names).to eq(%w[id status])
        expect(stats.column_names).to all(be_frozen)
        expect(names).to all(satisfy { |n| !n.frozen? })
      end

      it "rejects statistics for a column that isn't in the list" do
        expect do
          table({ "status" => column(n_distinct: 3.0) }, column_names: %w[id])
        end.to raise_error(ArgumentError, /status/)
      end

      it "rejects a name that's listed twice" do
        expect { table({}, column_names: %w[id status id]) }.to raise_error(ArgumentError, /twice: id/)
      end

      it "requires non-empty String names" do
        expect { table({}, column_names: ["id", ""]) }.to raise_error(ArgumentError, /column_names/)
        expect { table({}, column_names: [:id]) }.to raise_error(ArgumentError, /column_names/)
      end
    end

    describe "existing indexes" do
      let(:by_status) { index_on(orders, ["status"]) }

      it "maps each index name to its IndexCandidate, or to nil when from_ddl couldn't represent it" do
        stats = table({}, column_names: %w[id status], indexes: { "orders_status_idx" => by_status,
                                                                  "orders_lower_idx" => nil })

        expect(stats.indexes).to eq({ "orders_status_idx" => by_status, "orders_lower_idx" => nil })
        expect(stats.indexes).to be_frozen
      end

      it "keeps its own frozen copy of the map, leaving the caller's hash alone" do
        indexes = { "orders_status_idx" => by_status }
        stats = table({}, indexes:)
        indexes["other_idx"] = nil

        expect(stats.indexes.keys).to eq(["orders_status_idx"])
        expect(indexes).not_to be_frozen
      end

      it "requires a Hash" do
        [[["orders_status_idx", nil]], nil].each do |bad|
          expect { table({}, indexes: bad) }.to raise_error(ArgumentError, /indexes must be a Hash/), bad.inspect
        end
      end

      it "rejects an index on another table, or something that isn't a candidate" do
        other = Quaack::Enclave::TableName.new(schema: "public", name: "customers")

        expect { table({}, indexes: { "i" => index_on(other, ["id"]) }) }.to raise_error(ArgumentError, /customers/)
        expect { table({}, indexes: { "i" => "CREATE INDEX" }) }.to raise_error(ArgumentError, /IndexCandidate/)
        expect { table({}, indexes: { "" => by_status }) }.to raise_error(ArgumentError, /index name/)
      end
    end
  end

  it "redacts a partial index's predicate in inspect and pp, for a table and for the whole input" do
    sentinel = "SENTINEL-5d21e8"
    partial = Quaack::Enclave::IndexCandidate.new(table: orders, key: ["id"], predicate: "note = '#{sentinel}'",
                                                  sources: [:existing])
    table_stats = table({}, column_names: %w[id note], indexes: { "orders_partial_idx" => partial })
    stats = Quaack::Enclave::Statistics.new(tables: [table_stats])

    expect(partial.predicate).to include(sentinel)
    [table_stats, stats].each do |shown|
      [shown.inspect, PP.pp(shown, +"")].each do |text|
        expect(text).to include("predicate=<redacted>")
        expect(text).not_to include(sentinel)
      end
    end
  end

  # MCV values are real data, value-class under the README's trust boundary.
  # The readers and to_h give them back, but nothing that can end up in a
  # log may show them: inspect, to_s, pp, failed pattern matches, and error
  # messages.
  describe "keeping MCV values out of messages" do
    let(:sentinel) { "SENTINEL-c41b07" }
    let(:status) do
      Quaack::Enclave::ColumnStatistics.new(n_distinct: 3.0, null_frac: 0.0, correlation: nil,
                                            most_common_vals: ["#{sentinel}-a", "#{sentinel}-b"],
                                            most_common_freqs: [0.5, 0.25])
    end
    let(:table_stats) { table({ "status" => status }) }
    let(:stats) { Quaack::Enclave::Statistics.new(tables: [table_stats]) }

    it "plants the sentinel where the checks below look for it" do
      expect(status.most_common_vals.join).to include(sentinel)
      expect(status.to_h[:most_common_vals].join).to include(sentinel)
    end

    it "redacts the values in inspect, to_s, and pp, showing only how many there are" do
      [status, table_stats, stats].each do |shown|
        [shown.inspect, shown.to_s, PP.pp(shown, +"")].each do |text|
          expect(text).to include("most_common_vals=<2 redacted>", "most_common_freqs=[0.5, 0.25]")
          expect(text).not_to include(sentinel)
        end
      end
      expect(column(n_distinct: 1.0).inspect).to include("most_common_vals=nil")
    end

    # Everything a failed pattern match can show: the message, the full
    # report, and, for a missing key, the hash it was matching and the key.
    def pattern_error_text
      yield
      raise "expected the pattern not to match"
    rescue NoMatchingPatternKeyError => e
      [e.message, e.full_message(highlight: false), e.matchee.inspect, e.key.inspect].join("\n")
    rescue NoMatchingPatternError => e
      [e.message, e.full_message(highlight: false)].join("\n")
    end

    it "leaves them out of failed pattern matches, on the column, the table, and the whole input" do
      texts = [
        pattern_error_text { status => { most_common_vals: ["other"] } },
        pattern_error_text { status => { most_common_vals: Array, nope: 1 } },
        pattern_error_text { status => { nope: 1 } },
        pattern_error_text { status => [*, "other", *] },
        pattern_error_text { table_stats => { columns: { nope: 1 } } },
        pattern_error_text { table_stats => { nope: 1 } },
        pattern_error_text { table_stats => [*, "other", *] },
        pattern_error_text { stats => { tables: { nope: 1 } } },
        pattern_error_text { stats => [*, "other", *] }
      ]

      texts.each { |text| expect(text).not_to include(sentinel) }
    end

    # The whole report Ruby would print or log for the error, which includes
    # any exception it was raised from.
    def message_of
      yield
      raise "expected an error"
    rescue ArgumentError, KeyError => e
      e.full_message(highlight: false)
    end

    # The literal is value-class too.
    it "leaves the literal out of value_frequency's errors" do
      messages = [message_of { table_stats.value_frequency("nope", "#{sentinel}-a") },
                  message_of { table_stats.value_frequency("status", ["#{sentinel}-a"]) }]

      expect(messages[0]).to include("nope")
      expect(messages[1]).to include("literal_text")
      messages.each { |message| expect(message).not_to include(sentinel) }
    end

    it "leaves them out of every error the constructor raises" do
      mcv = ["#{sentinel}-a"]
      bad = [
        -> { column_with(mcv, nil) },
        -> { column_with([*mcv, 1], [0.5, 0.25]) },
        -> { column_with(mcv, "#{sentinel}-f") },
        -> { column_with(mcv, [0.5, 0.25]) },
        -> { column_with(mcv, ["#{sentinel}-f"]) },
        -> { column_with(%w[x], mcv) },
        -> { column_with([*mcv, "b"], [0.75, 0.5]) }
      ]

      messages = bad.map { |make| message_of(&make) }
      expect(messages).to all(include("most_common_"))
      messages.each { |message| expect(message).not_to include(sentinel) }
    end

    def column_with(vals, freqs)
      Quaack::Enclave::ColumnStatistics.new(n_distinct: 3.0, null_frac: 0.0, correlation: nil,
                                            most_common_vals: vals, most_common_freqs: freqs)
    end

    it "hides the values from pattern matching, but still matches the other members" do
      expect(status.deconstruct_keys(nil)).not_to have_key(:most_common_vals)
      expect(status.deconstruct_keys(%i[most_common_vals n_distinct])).to eq({ n_distinct: 3.0 })
      expect(status).not_to respond_to(:deconstruct)
      hides_values = (status in { most_common_vals: Array })
      matches_the_rest = (status in { n_distinct: 3.0, most_common_freqs: [0.5, 0.25] })

      expect([hides_values, matches_the_rest]).to eq([false, true])
    end
  end

  it "keeps its helpers off the public API" do
    %i[in_range most_common check_most_common strings? frequency].each do |name|
      expect(column(n_distinct: 1.0)).not_to respond_to(name)
    end
    stats = table({})
    %i[finite names_of check_no_repeats column_map index_map check_index other_value_frequency].each do |name|
      expect(stats).not_to respond_to(name)
    end
  end

  describe Quaack::Enclave::Statistics do
    let(:orders_stats) { table({ "status" => column(n_distinct: 3.0) }) }
    let(:stats) { described_class.new(tables: [orders_stats]) }

    it "looks tables up by an equal TableName" do
      lookup = Quaack::Enclave::TableName.new(schema: "public", name: "orders")

      expect(stats.table(lookup)).to equal(orders_stats)
      expect(stats.table?(lookup)).to be(true)
    end

    it "raises KeyError naming the table when it's missing" do
      other = Quaack::Enclave::TableName.new(schema: "public", name: "customers")

      expect { stats.table(other) }.to raise_error(KeyError, /public\.customers/)
      expect(stats.table?(other)).to be(false)
    end

    it "keeps its tables in a frozen map" do
      expect(stats.tables).to be_frozen
      expect(stats.tables).to eq({ orders => orders_stats })
    end

    it "requires TableStatistics entries" do
      expect { described_class.new(tables: [orders]) }.to raise_error(ArgumentError, /TableStatistics/)
    end

    it "rejects two entries for the same table" do
      expect do
        described_class.new(tables: [orders_stats, orders_stats])
      end.to raise_error(ArgumentError, /public\.orders/)
    end
  end
end
