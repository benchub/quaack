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
    "an integer column under integer division" => ["100 / a.points > 2", "100 / a.points > 3"],
    "an integer column cast to numeric" => ["a.points::numeric / 3 > 2", "a.points::numeric / 3 > 2.5"],
    "an integer column under CAST" => ["CAST(a.points AS numeric) / 3 > 2", "CAST(a.points AS numeric) / 3 > 2.5"]
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
    def values(original, candidate) = with_nulls(original, candidate).compact

    def with_nulls(original, candidate)
      queries = [select + original, select + candidate]
      footprint = fuzz.send(:footprint, queries)
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, footprint)
      Quaack::Enclave::Fuzz::Domains.new(conn, catalog, queries).values(footprint.first, "points_possible")
    end

    it "puts the solutions and their neighbours right after the column's first value" do
      expect(values("100 / a.points_possible > 2", "100 / a.points_possible > 3").first(10))
        .to eq(%w[2 50 33.3333333333333333 34 33 51 49 50.000001 49.999999 34.3333333333333333])
    end

    it "puts them right after the column's first value that isn't NULL, when its values start with NULL" do
      got = with_nulls("(a.points_possible IS NULL OR 100 / a.points_possible > 2)",
                       "(a.points_possible IS NULL OR 100 / a.points_possible > 3)")

      expect(got.first(6)).to match([nil, a_kind_of(String), "50", "33.3333333333333333", "34", "33"])
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

    # A subquery's column matches every table's column of its name, so a
    # boolean column of the same name, which takes no number, gets none,
    # and nothing breaks.
    it "gives a column of the same name that holds no number none of them" do
      conn.exec("CREATE TABLE fx.flags (id bigint PRIMARY KEY, points_possible boolean)")
      from = "SELECT a.id FROM fx.assignments a JOIN fx.flags f ON f.id = a.id " \
             "JOIN (SELECT id, points_possible FROM fx.assignments) s ON s.id = a.id WHERE f.points_possible AND "
      queries = [2, 3].map { "#{from}100 / s.points_possible > #{it}" }
      footprint = fuzz.send(:footprint, queries)
      domains = Quaack::Enclave::Fuzz::Domains.new(conn, Quaack::Enclave::Fuzz::Catalog.new(conn, footprint), queries)

      flags, assignments = %w[flags assignments].map { |name| footprint.find { it.name == name } }

      expect(domains.values(flags, "points_possible").compact).to eq([])
      expect(domains.values(assignments, "points_possible")).to include("50", "33.3333333333333333")
    end
  end

  # Task 20261012-33: a qualified column's solutions go to its own table,
  # not to a joined table's column of the same name, where they'd take
  # enumerate's first classes.
  it "gives the solutions to the qualified column's table, not to a joined table's column of its name" do
    conn.exec("CREATE TABLE fx.grades (id bigint PRIMARY KEY, points_possible numeric)")
    from = "SELECT a.id FROM fx.assignments a JOIN fx.grades g ON g.id = a.id WHERE g.points_possible > 7 AND "
    queries = [2, 3].map { "#{from}100 / a.points_possible > #{it}" }
    footprint = fuzz.send(:footprint, queries)
    domains = Quaack::Enclave::Fuzz::Domains.new(conn, Quaack::Enclave::Fuzz::Catalog.new(conn, footprint), queries)

    grades, assignments = %w[grades assignments].map { |name| footprint.find { it.name == name } }

    expect(domains.values(assignments, "points_possible")).to include("50", "33.3333333333333333")
    expect(domains.values(grades, "points_possible")).not_to include("50", "33.3333333333333333", "34", "33")
  end

  describe Quaack::Enclave::Fuzz::Thresholds do
    let(:t) { Quaack::Enclave::TableName.new(schema: "fx", name: "t") }
    let(:u) { Quaack::Enclave::TableName.new(schema: "fx", name: "u") }

    def thresholds(*wheres, from: "fx.t a")
      trees = wheres.map { PgQuery.parse("SELECT 1 FROM #{from} WHERE #{it}").tree.to_h }
      described_class.new(conn, Quaack::Enclave::Fuzz::Facts.new(trees))
    end

    it "solves each comparison's boundary, then its floor and ceiling, in the queries' order" do
      expect(thresholds("100 / a.p > 2", "100 / a.p > 3").values(t, "p"))
        .to eq(%w[50 33.3333333333333333 34 33])
      expect(thresholds("a.p * 0.9 >= 45", "0.9 * a.p >= 46").values(t, "p"))
        .to eq(%w[50 51.1111111111111111 52 51])
    end

    it "solves +, - and / with the column on either side, a comparison either way round, and BETWEEN" do
      solved = thresholds("a.p + 5 = 12", "7 - a.p < 3", "a.p - 2 <> 9", "a.p / 4 <= 3", "20 > a.p * 2",
                          "a.p * 2 BETWEEN 10 AND 21", "3 + a.p >= 9")
      expect(solved.values(t, "p")).to eq(%w[7 4 11 12 10 5 10.5 6])
    end

    it "takes only a column it combines with a number, and never divides by zero or overflows" do
      solved = thresholds("100 / a.p > 0", "a.p / 0 > 1", "a.p * 0 = 5", "0 / a.p = 0", "a.q * 2 > 9",
                          "a.p * a.r > 3", "a.p || 'x' = 'yx'", "a.p * 2 > a.r", "a.p * 2 > 1e200000")
      expect(solved.values(t, "p")).to eq([])
      expect(solved.values(t, "q")).to eq(%w[4.5 5 4])
    end

    it "looks through a cast on the column, as :: or CAST, nested or not" do
      solved = thresholds("a.p::numeric / 3 > 2", "CAST(a.p AS numeric) / 3 > 2.5", "a.p::int4::numeric * 2 = 9")
      expect(solved.values(t, "p")).to eq(%w[6 7.5 8 7 4.5 5 4])
    end

    it "gives a qualified column's solutions to its own table, and an unqualified column's to every table" do
      solved = thresholds("a.p * 2 > 9", "b.p + 1 = 5", "fx.u.p - 1 = 7", "p - 3 = 10",
                          from: "fx.t a JOIN fx.u b ON true")
      expect(solved.values(t, "p")).to eq(%w[4.5 5 4 13])
      expect(solved.values(u, "p")).to eq(%w[4 8 13])
    end

    it "resolves a qualifier in the innermost query that has it, and gives a subquery's or CTE's column's " \
       "solutions to every table" do
      solved = thresholds("EXISTS (SELECT 1 FROM fx.u a WHERE a.p * 2 > 9 AND b.p + 1 = 5) AND a.p - 1 = 7",
                          "s.p * 3 = 6",
                          "EXISTS (WITH c AS (SELECT 1 AS p) SELECT 1 FROM c WHERE c.p + 2 = 3)",
                          "EXISTS (SELECT 1 FROM (SELECT 1 AS p) a WHERE a.p * 5 = 35)",
                          from: "fx.t a JOIN fx.u b ON true JOIN (SELECT 1 AS p) s ON true")
      expect(solved.values(t, "p")).to eq(%w[8 2 1 7])
      expect(solved.values(u, "p")).to eq(%w[4.5 5 4 2 1 7])
    end

    it "skips nested arithmetic, IN lists and parameters without raising" do
      solved = thresholds("(a.p * 2) + 3 > 9", "a.p * 2 IN (4, 6)", "a.p IN (4, 6)", "a.p * 2 > $1",
                          "a.p * $1 > 4", "(a.p::numeric * 2) + 3 > 9")
      expect(solved.values(t, "p")).to eq([])
    end
  end
end
