# frozen_string_literal: true

require "quaack/enclave/fuzz"

# Values for a column the queries combine with a constant and compare with
# another (task 20261012-23, DESIGN.md's rewrite-test): a wrong threshold on
# 100 / points_possible or points_possible * 0.9 differs only in a band of
# the column's values that no constant of the queries, nor any neighbour of
# one, falls in. The values that solve each comparison's boundary do.
RSpec.describe "Quaack::Enclave::Fuzz's values that solve a comparison's boundary" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:fuzz) { Quaack::Enclave::Fuzz }
  let(:select) { "SELECT a.id, a.course_id FROM fx.assignments a WHERE a.course_id = 1 AND " }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.assignments (id bigint PRIMARY KEY, course_id bigint, points_possible numeric,
        points integer);
    SQL
  end

  pairs = {
    "a constant divided by the column" => ["100 / a.points_possible > 2", "100 / a.points_possible > 3"],
    "the column times a constant, a step off" => ["a.points_possible * 0.9 >= 45", "a.points_possible * 0.9 >= 46"],
    "the column times a constant, strict" => ["a.points_possible * 0.9 >= 45", "a.points_possible * 0.9 > 45"],
    "the column times a constant, a fraction off" => ["a.points_possible * 0.9 > 45",
                                                      "a.points_possible * 0.9 > 45.5"],
    "an integer column under integer division" => ["100 / a.points > 2", "100 / a.points > 3"]
  }

  describe "the fuzz search" do
    pairs.each do |name, (original, candidate)|
      it "disproves a wrong threshold on #{name}" do
        result = fuzz.run(conn, select + original, select + candidate, stop: fuzz::StopRule.trials(1500))

        expect(result).to have_attributes(verdict: :disproved, rule: :row_count)
      end
    end
  end

  # Enumerate's classes for a read column are its first 6 base values, so
  # the solutions must come before the pools' many others.
  describe "enumerate, after a fuzz pass" do
    pairs.each do |name, (original, candidate)|
      it "disproves a wrong threshold on #{name} in its first worlds" do
        result = fuzz.search(conn, select + original, select + candidate, stop: fuzz::StopRule.trials(1),
                                                                          enumerate: fuzz::Enumerate::Limit.worlds(200))

        expect(result.fuzz.verdict).to eq(:passed)
        expect(result.enumerate).to have_attributes(verdict: :disproved, rule: :row_count)
      end
    end
  end

  describe "a column's base values" do
    def values(original, candidate)
      queries = [select + original, select + candidate]
      footprint = fuzz.send(:footprint, queries)
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, footprint)
      Quaack::Enclave::Fuzz::Domains.new(conn, catalog, queries).values(footprint.first, "points_possible").compact
    end

    it "puts the solutions and their neighbours right after the column's first value" do
      expect(values("100 / a.points_possible > 2", "100 / a.points_possible > 3").first(10))
        .to eq(%w[2 50 33.3333333333333333 34 33 51 49 50.000001 49.999999 34.3333333333333333])
    end

    it "writes them as the column's type writes them" do
      conn.exec("ALTER TABLE fx.assignments ALTER COLUMN points_possible TYPE numeric(6, 2)")

      got = values("100 / a.points_possible > 2", "100 / a.points_possible > 3")

      expect(got).to include("50.00", "33.33", "34.00", "33.34")
      expect(got).not_to include("33.3333333333333333")
    end

    it "keeps only those its CHECKs allow" do
      conn.exec("ALTER TABLE fx.assignments ADD CHECK (points_possible < 40)")

      got = values("100 / a.points_possible > 2", "100 / a.points_possible > 3")

      expect(got).to include("33.3333333333333333", "34", "33")
      expect(got).not_to include("50", "51", "49")
    end
  end

  describe Quaack::Enclave::Fuzz::Thresholds do
    def thresholds(*wheres)
      trees = wheres.map { PgQuery.parse("SELECT 1 FROM fx.t a WHERE #{it}").tree.to_h }
      described_class.new(conn, Quaack::Enclave::Fuzz::Facts.new(trees))
    end

    it "solves each comparison's boundary, then its floor and ceiling, in the queries' order" do
      expect(thresholds("100 / a.p > 2", "100 / a.p > 3").values("p"))
        .to eq(%w[50 33.3333333333333333 34 33])
      expect(thresholds("a.p * 0.9 >= 45", "0.9 * a.p >= 46").values("p"))
        .to eq(%w[50 51.1111111111111111 52 51])
    end

    it "solves +, - and / with the column on either side, a comparison either way round, and BETWEEN" do
      solved = thresholds("a.p + 5 = 12", "7 - a.p < 3", "a.p - 2 <> 9", "a.p / 4 <= 3", "20 > a.p * 2",
                          "a.p * 2 BETWEEN 10 AND 21", "3 + a.p >= 9")
      expect(solved.values("p")).to eq(%w[7 4 11 12 10 5 10.5 6])
    end

    it "takes only a column it combines with a number, and never divides by zero or overflows" do
      solved = thresholds("100 / a.p > 0", "a.p / 0 > 1", "a.p * 0 = 5", "0 / a.p = 0", "a.q * 2 > 9",
                          "a.p * a.r > 3", "a.p || 'x' = 'yx'", "a.p * 2 > a.r", "a.p * 2 > 1e200000")
      expect(solved.values("p")).to eq([])
      expect(solved.values("q")).to eq(%w[4.5 5 4])
    end
  end
end
