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
  def outgoing(original, candidate)
    results = fuzz.search(conn, original, candidate, stop: fuzz::StopRule.trials(8), enumerate: nil, seed: 7)
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
