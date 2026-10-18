# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare's check of GROUP BY keys and min or max (task
# 20261018-28). Each keeps one of several values Postgres calls equal, and
# numeric's 10 and 10.0 print differently, so the value printed follows the
# load order. The checked run fails when a group's key, or the values tied
# for its min or max, print differently.
RSpec.describe Quaack::Enclave::ResultComparison do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }

  before { conn.exec("CREATE TABLE items (id integer PRIMARY KEY, grp integer NOT NULL, n numeric)") }

  def rows(*values)
    values.map do |id, grp, n|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp n], values: [id.to_s, grp.to_s, n])
    end
  end

  # grp 1 holds 10 and 10.0, equal values that print differently.
  let(:equal_numerics) { rows([1, 1, "10"], [2, 1, "10.0"], [3, 2, "5"]) }
  let(:plain_numerics) { rows([1, 1, "10"], [2, 1, "10"], [3, 2, "5"], [4, 2, nil], [5, 3, nil]) }

  def verdict(original, candidate = original, data: equal_numerics)
    runner.with_fixture(data) { |tx| described_class.compare(tx, original:, candidate:) }.to_h.slice(:match, :rule)
  end

  def in_load_orders(original, data: equal_numerics)
    described_class.compare_in_load_orders(runner, data, original:, candidate: original).to_h.slice(:match, :rule)
  end

  let(:refused) { { match: false, rule: :unsupported_order } }
  let(:matched) { { match: true, rule: nil } }

  it "refuses a GROUP BY key whose group prints two ways, named by expression, position, and alias" do
    ["SELECT n FROM items GROUP BY n", "SELECT n FROM items GROUP BY 1", "SELECT n AS m FROM items GROUP BY m",
     "SELECT grp, s.n FROM (SELECT grp, n FROM items GROUP BY grp, n) s"].each do |sql|
      expect(verdict(sql)).to eq(refused), sql
    end
    expect(in_load_orders("SELECT n FROM items GROUP BY n")).to eq(refused)
  end

  it "refuses a min or max whose tied values print two ways" do
    expect(verdict("SELECT grp, max(n) FROM items GROUP BY grp")).to eq(refused)
    expect(verdict("SELECT min(n) FROM items WHERE grp = 1")).to eq(refused)
    expect(verdict("SELECT max(n) FROM items", data: rows([1, 1, "10"], [2, 1, "10.0"], [3, 1, nil])))
      .to eq(refused)
  end

  it "checks a filtered max's ties among the rows its FILTER keeps" do
    expect(verdict("SELECT max(n) FILTER (WHERE grp = 1) FROM items",
                   data: rows([1, 1, "10"], [2, 1, "10.0"], [3, 2, "11"]))).to eq(refused)
  end

  it "leaves a window max alone" do
    expect(verdict("SELECT id, max(n) OVER (PARTITION BY grp) FROM items")).to eq(matched)
  end

  it "refuses when the original's own pick decides its answer, though a candidate with none matches by luck" do
    expect(verdict("SELECT n FROM items GROUP BY n", "SELECT n FROM items WHERE id <> 2")).to eq(refused)
  end

  it "matches a min or max whose ties print the same, though the group holds 10 and 10.0" do
    expect(verdict("SELECT grp, min(n) FROM items GROUP BY grp",
                   data: rows([1, 1, "10"], [2, 1, "10.0"], [3, 1, "5"], [4, 2, "5"]))).to eq(matched)
    expect(verdict("SELECT max(n) FROM items", data: rows([1, 1, "10"], [2, 1, "10.0"], [3, 1, "11"])))
      .to eq(matched)
  end

  it "matches GROUP BY keys and min or max that print one way, with NULLs and empty groups" do
    ["SELECT n, count(*) FROM items GROUP BY n", "SELECT grp, min(n), max(n) FROM items GROUP BY grp",
     "SELECT max(n) FROM items WHERE id > 99",
     "SELECT grp, n FROM items GROUP BY grp, n, id HAVING count(*) > 0"].each do |sql|
      expect(verdict(sql, data: plain_numerics)).to eq(matched), sql
    end
  end

  it "counts a GROUP BY or a min or max as a pick for the fuzz session's comparison" do
    picks = Quaack::Enclave::ResultComparison::Picks
    expect(["SELECT n FROM items GROUP BY n", "SELECT max(n) FROM items", "SELECT n FROM items"]
      .map { picks.any?(it, "SELECT n FROM items") }).to eq([true, true, false])
  end

  it "still fails a candidate whose answer differs" do
    expect(verdict("SELECT grp, max(n) FROM items GROUP BY grp", "SELECT grp, min(n) FROM items GROUP BY grp",
                   data: rows([1, 1, "10"], [2, 1, "11"])))
      .to eq(match: false, rule: :multiset)
  end
end
