# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare's check of window functions over tied rows (task
# 20261015-5). row_number, ntile, lag and lead number or read rows in their
# window's order, so rows that tie on it can come out either way: they're
# picks, forced by each FROM item's row text and checked like the others.
# rank and its kin, and an ordinary aggregate over its default frame, give
# tied rows one value, so they pick nothing. Any other window, or a named
# one, refuses as unforceable_pick.
RSpec.describe Quaack::Enclave::ResultComparison do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }
  let(:sentinel) { "SENTINEL_9f3c" }

  before do
    conn.exec("CREATE TABLE items (id integer PRIMARY KEY, grp integer NOT NULL, label text)")
  end

  # grp 1 holds three rows in label order, grp 2 one. Six rows or fewer, so
  # a sort keeps its input order for ties.
  let(:fixture) do
    [[1, 1, "a"], [2, 1, "b"], [3, 1, sentinel], [4, 2, "d"]].map do |id, grp, label|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp label],
                                                   values: [id.to_s, grp.to_s, label])
    end
  end

  def compare(original, candidate)
    runner.with_fixture(fixture) { |tx| described_class.compare(tx, original:, candidate:) }
  end

  def raw(sql) = runner.with_fixture(fixture) { |tx| tx.query(sql).rows }
  def fields(verdict) = verdict.to_h.slice(:match, :rule, *(:reason if verdict.reason))

  def dedupe(window) = "SELECT grp, label FROM (SELECT grp, label, #{window} AS rn FROM items) s WHERE rn = 1"

  let(:keyed) { dedupe("row_number() OVER (PARTITION BY grp ORDER BY label)") }
  let(:loose) { dedupe("row_number() OVER (PARTITION BY grp)") }

  it "is a mismatch for a candidate whose row_number drops the key that picks the kept row" do
    # Loaded forward, the loose window keeps label a, as the keyed one does.
    expect(raw(loose).sort).to eq([%w[1 a], %w[2 d]])

    expect(fields(compare(keyed, loose))).to eq(match: false, rule: :multiset)
  end

  it "matches a candidate whose row_number has no ties" do
    candidate = dedupe("row_number() OVER (PARTITION BY grp ORDER BY id)")

    expect(fields(compare(keyed, candidate))).to eq(match: true, rule: nil)
  end

  it "refuses, without the data, when the original's row_number turns on tied rows" do
    verdict = compare(loose, keyed)

    expect(fields(verdict)).to eq(match: false, rule: :unsupported_order, reason: :original_pick)
    expect(verdict.to_h.to_s).not_to include(sentinel)
  end

  it "refuses when the original's lag reads a tied neighbor" do
    original = "SELECT id, lag(label) OVER (PARTITION BY grp ORDER BY grp) FROM items"

    expect(fields(compare(original, original))).to eq(match: false, rule: :unsupported_order, reason: :original_pick)
  end

  it "forces a frame of rows, matching a moving sum over a unique key and refusing one over ties" do
    moving = ->(key) { "SELECT id, sum(id) OVER (ORDER BY #{key} ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM items" }

    expect(fields(compare(moving.call("id"), moving.call("id")))).to eq(match: true, rule: nil)
    expect(fields(compare(moving.call("grp"), moving.call("grp"))))
      .to eq(match: false, rule: :unsupported_order, reason: :original_pick)
  end

  it "refuses a frame of rows that excludes ties as unforceable" do
    original = "SELECT id, sum(id) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING EXCLUDE TIES) FROM items"

    expect(fields(compare(original, original))).to eq(match: false, rule: :unsupported_order, reason: :unforceable_pick)
  end

  it "picks nothing with rank or a default-frame count over ties" do
    %w[rank() count(*)].each do |call|
      original = "SELECT id, #{call} OVER (PARTITION BY grp ORDER BY grp) FROM items"

      expect(fields(compare(original, original))).to eq(match: true, rule: nil)
    end
  end

  it "refuses first_value and a named window as unforceable, without the data" do
    ["SELECT id, first_value(label) OVER (PARTITION BY grp ORDER BY grp) FROM items",
     "SELECT id, row_number() OVER w FROM items WINDOW w AS (PARTITION BY grp ORDER BY id)"].each do |original|
      verdict = compare(original, original)

      expect(fields(verdict)).to eq(match: false, rule: :unsupported_order, reason: :unforceable_pick)
      expect(verdict.to_h.to_s).not_to include(sentinel)
    end
  end
end
