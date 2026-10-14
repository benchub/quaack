# frozen_string_literal: true

require "quaack/enclave/fuzz"

# A standing trust-boundary guard (20261010-47, made the search's by task
# 20261012-4): the per-atom caution crosses the boundary as the redacted
# shapes of the atoms the search never showed both true and false. Whether a
# random world reaches an atom can follow a count threshold (fuzz's copies
# stop at 101 rows a table, so HAVING count(*) > 200 is never true), so for a
# query whose reach can follow a literal the search reports the worst case,
# every atom untested, the same for every literal (Fuzz::Reach, DESIGN.md's
# 20261011-2 rule). Here every count threshold from 0 to 10, under every
# comparison operator, must give a byte-identical caution and verdict.
RSpec.describe "The search's caution across literals" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:fuzz) { Quaack::Enclave::Fuzz }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.posts (id integer PRIMARY KEY, user_id integer NOT NULL REFERENCES fx.users,
                             score integer NOT NULL, published boolean NOT NULL);
    SQL
  end

  # The verdict and its rule, and the caution (the paths into the parse stay
  # in the enclave). How many trials a search ran isn't held to this: it
  # follows how long each trial takes, under the real stop rule.
  def outgoing(original, candidate, trials: 8)
    results = fuzz.search(conn, original, candidate, stop: fuzz::StopRule.trials(trials), enumerate: nil, seed: 7)
    [results.fuzz.verdict, results.fuzz.rule, results.coverage.to_h.except(:untested_paths)]
  end

  thresholds = (0..10).to_a.freeze
  operators = %w[> >= = < <= <>].freeze
  users = "SELECT fx.users.id FROM fx.users WHERE"
  count = "(SELECT count(*) FROM fx.posts WHERE fx.posts.user_id = fx.users.id)"

  families = operators.to_h do |op|
    ["count(*) #{op} threshold", ->(n) { "#{users} #{count} #{op} #{n}" }]
  end.merge(
    operators.to_h do |op|
      ["derived count #{op} threshold", lambda { |n|
        "SELECT t.uid FROM (SELECT fx.posts.user_id AS uid, count(*) AS k FROM fx.posts " \
          "GROUP BY fx.posts.user_id) t WHERE t.k #{op} #{n}"
      }]
    end,
    operators.to_h do |op|
      ["CTE count #{op} threshold", lambda { |n|
        "WITH t AS (SELECT fx.posts.user_id AS uid, count(*) AS k FROM fx.posts GROUP BY fx.posts.user_id) " \
          "SELECT t.uid FROM t WHERE #{n} #{op} t.k"
      }]
    end,
    operators.to_h do |op|
      ["HAVING count() #{op} threshold", lambda { |n|
        "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
          "GROUP BY fx.users.id HAVING count(fx.posts.id) #{op} #{n} AND max(fx.posts.score) > 2"
      }]
    end
  ).freeze

  # A cut's literals (LIMIT, OFFSET, FETCH FIRST), at the top or in a
  # subquery or CTE, decide which rows a world's result keeps, so coverage
  # judges the original with every cut removed, the same for every value.
  # LIMIT 0 is in the family: the cut goes, so it's judged like the rest.
  # The cut's literal still shapes which worlds are drawn, as every literal
  # does (its value and row counts near it are in the pools), so a search
  # long enough to settle each atom is what's held the same here.
  posts = "SELECT fx.posts.user_id FROM fx.posts WHERE fx.posts.published AND fx.posts.score > 3 ORDER BY fx.posts.id"
  cuts = {
    "OFFSET" => [[0, 2, 5, 8, 20, 60, 120, 10_000], ->(n) { "#{posts} LIMIT 20 OFFSET #{n}" }],
    "LIMIT" => [[0, 1, 5, 120], ->(n) { "#{posts} LIMIT #{n}" }],
    "FETCH FIRST" => [[0, 1, 5, 120], ->(n) { "#{posts} FETCH FIRST #{n} ROWS ONLY" }],
    "subquery OFFSET" => [[0, 2, 5, 20, 120], lambda { |n|
      "SELECT fx.users.id FROM fx.users WHERE fx.users.name <> 'x' AND fx.users.id IN (#{posts} LIMIT 20 OFFSET #{n})"
    }],
    "CTE LIMIT" => [[0, 1, 5, 120], ->(n) { "WITH t AS (#{posts} LIMIT #{n}) SELECT t.user_id FROM t" }]
  }.freeze

  cuts.each do |name, (values, make)|
    it "cautions the same for every #{name} value, judging the atoms with the cut removed" do
      by_value = values.to_h do |n|
        [n, outgoing(make.call(n), make.call(n).sub("WHERE", "WHERE true AND"), trials: 100)]
      end
      expect(by_value.values.uniq.size).to eq(1), classes(by_value).join("\n")
      caution = by_value.values.first.last
      expect(caution[:untested_atoms].size).to be < caution[:atoms]
    end
  end

  # The guard catches a caution that follows the cut: with the cut left in,
  # OFFSET 0 shows both atoms both ways, and OFFSET 10000 leaves every world's
  # rows before the page, so none.
  it "catches a caution that follows the cut, when the uncutting is planted away" do
    allow(fuzz::Uncut).to receive(:uncut!)
    make = cuts.fetch("OFFSET").last

    by_value = [0, 10_000].to_h do |n|
      [n, outgoing(make.call(n), make.call(n).sub("WHERE", "WHERE true AND"), trials: 100)]
    end

    expect(by_value.values.uniq.size).to eq(2), classes(by_value).join("\n")
  end

  def classes(by_value) = by_value.group_by { |_, out| out }.map { |out, pairs| "#{pairs.map(&:first)}: #{out}" }

  families.each do |name, make|
    it "cautions the same for every #{name} value" do
      by_value = thresholds.to_h { |n| [n, outgoing(make.call(n), "#{make.call(n)} AND true")] }
      expect(by_value.values.uniq.size).to eq(1), classes(by_value).join("\n")
      caution = by_value.values.first.last
      expect(caution[:untested_atoms]).to eq((0...caution[:atoms]).to_a)
    end
  end

  # The guard catches a caution that follows the threshold: with the worst
  # case turned off, count(*) >= 0 is never false and count(*) > 0 is both,
  # so the two caution differently, and the comparison above says so.
  it "catches a caution that follows the threshold, when the worst case is planted away" do
    allow(fuzz::Reach).to receive(:worst_case?).and_return(false)
    make = families.fetch("count(*) >= threshold")

    by_value = [0, 1].to_h { |n| [n, outgoing(make.call(n), "#{make.call(n)} AND true")] }

    expect(by_value.values.uniq.size).to eq(2), classes(by_value).join("\n")
  end
end
