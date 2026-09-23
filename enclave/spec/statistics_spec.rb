# frozen_string_literal: true

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
      name = described_class.new(schema:, name: +"orders")
      schema << "_changed"

      expect(name.schema).to eq("public")
      expect([name.schema, name.name]).to all(be_frozen)
      expect(schema).not_to be_frozen
    end

    it "requires a non-empty schema and name" do
      expect { described_class.new(schema: "", name: "orders") }.to raise_error(ArgumentError, /schema/)
      expect { described_class.new(schema: nil, name: "orders") }.to raise_error(ArgumentError, /schema/)
      expect { described_class.new(schema: "public", name: "") }.to raise_error(ArgumentError, /name/)
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

      it "rejects an index on another table, or something that isn't a candidate" do
        other = Quaack::Enclave::TableName.new(schema: "public", name: "customers")

        expect { table({}, indexes: { "i" => index_on(other, ["id"]) }) }.to raise_error(ArgumentError, /customers/)
        expect { table({}, indexes: { "i" => "CREATE INDEX" }) }.to raise_error(ArgumentError, /IndexCandidate/)
        expect { table({}, indexes: { "" => by_status }) }.to raise_error(ArgumentError, /index name/)
      end
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
