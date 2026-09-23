# frozen_string_literal: true

require "quaack/enclave/statistics"

RSpec.describe "the statistics input" do
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }

  def column(n_distinct:, null_frac: 0.0, correlation: nil)
    Quaack::Enclave::ColumnStatistics.new(n_distinct:, null_frac:, correlation:)
  end

  def table(columns, reltuples: 1000.0, name: orders)
    Quaack::Enclave::TableStatistics.new(name:, reltuples:, columns:)
  end

  describe Quaack::Enclave::TableName do
    it "compares by value, so it works as a hash key" do
      same = described_class.new(schema: "public", name: "orders")

      expect({ orders => 1 }[same]).to eq(1)
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
      expect { column(n_distinct: 1.0, correlation: 1.5) }.to raise_error(ArgumentError, /correlation/)
      expect { table({}, reltuples: "many") }.to raise_error(ArgumentError, /reltuples/)
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

    it "rejects two entries for the same table" do
      expect do
        described_class.new(tables: [orders_stats, orders_stats])
      end.to raise_error(ArgumentError, /public\.orders/)
    end
  end
end
