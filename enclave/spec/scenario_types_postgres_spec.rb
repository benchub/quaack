# frozen_string_literal: true

require "bigdecimal"
require "quaack/enclave/arena_schema"
require "quaack/enclave/scenarios"

# The values a counterexample round's parent rows take for the types
# beyond numbers, text, and dates (20261003-27): distinct values that fit
# narrow numerics, bit strings and short strings. (Task 20261012-4
# removed the scenario fixtures these once built.)
RSpec.describe Quaack::Enclave::Scenarios::Values do
  let(:conn) { racetrack_and_arena.arena.connection }

  before { conn.exec("CREATE SCHEMA fx") }

  def column(table, name)
    Quaack::Enclave::ArenaSchema.load(conn, [tn(table)]).column(tn(table), name)
  end

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  describe "Values#nth and #readable?" do
    let(:values_for) { described_class.new(conn) }

    before do
      conn.exec("CREATE TABLE fx.t (sm smallint, sc numeric(5,2), tiny numeric(2,0), big bigint)")
    end

    it "gives distinct values that fit, for numbers past the type's range" do
      %w[sm sc tiny].each do |name|
        col = column("t", name)
        numbers = [1, 5, 99, 999, 50_001, 100_001, 100_005]
        nths = numbers.map { |n| values_for.nth(col, n) }
        expect(nths.map { |s| BigDecimal(s) }.uniq.size).to eq(numbers.size), "#{name}: #{nths}"
      end
    end

    it "keeps a wide type's number as it is" do
      expect(values_for.nth(column("t", "big"), 100_005)).to eq("100005")
      expect(values_for.nth(column("t", "sm"), 5)).to eq("5")
    end

    it "tells apart what two typmods of one type read" do
      conn.exec("ALTER TABLE fx.t ADD wide numeric(20,2)")
      expect(values_for.readable?(column("t", "wide"), "99999999")).to be(true)
      expect(values_for.readable?(column("t", "sc"), "99999999")).to be(false)
    end

    it "gives a bit varying with no length as many distinct values as it needs" do
      conn.exec("CREATE TABLE fx.b (vb bit varying UNIQUE)")
      nths = (1..10).map { values_for.nth(column("b", "vb"), it) }
      expect(nths.uniq.size).to eq(10), nths.to_s
      nths.each { conn.exec_params("INSERT INTO fx.b (vb) VALUES ($1)", [it]) }
    end

    it "reads a value as an insert does, so a varchar(n) or char(n) never truncates distinct values" do
      conn.exec("CREATE TABLE fx.s (vc varchar(2) UNIQUE, ch char(2) UNIQUE)")
      %w[vc ch].each do |name|
        col = column("s", name)
        expect(values_for.readable?(col, "k10")).to be(false)
        nths = (1..12).map { values_for.nth(col, it) }
        expect(nths.uniq.size).to eq(12), "#{name}: #{nths}"
        nths.each { conn.exec_params("INSERT INTO fx.s (#{name}) VALUES ($1)", [it]) }
      end
    end
  end

  it "wraps a unique domain over a narrow numeric" do
    conn.exec(<<~SQL)
      CREATE DOMAIN fx.points AS numeric(5,2); CREATE DOMAIN fx.score AS fx.points;
      CREATE TABLE fx.t (p fx.points, s fx.score);
    SQL
    %w[p s].each do |name|
      nth = described_class.new(conn).nth(column("t", name), 100_005)
      expect(conn.exec_params("SELECT $1::fx.points", [nth]).getvalue(0, 0)).to eq(nth)
    end
  end
end
