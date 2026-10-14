# frozen_string_literal: true

require "quaack/enclave/fuzz"

# Task 20261012-4's fix round: which of the loosened originals Coverage
# checks on a world give rows other than the original's (Fuzz::Differ). They
# go to the server in one statement, compared as multisets, and each that
# differs there is confirmed with the official comparison, so neither a
# tied row's order nor float noise counts as the atom mattering.
RSpec.describe Quaack::Enclave::Fuzz::Differ do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA d;
      CREATE TABLE d.t (id integer PRIMARY KEY, g integer NOT NULL, f float8 NOT NULL, j json);
      INSERT INTO d.t VALUES (1, 1, 0.1, '{"a": 1}'), (2, 1, 0.2, '{"a": 2}'), (3, 2, 0.3, '{"a": 3}');
    SQL
    conn.exec("BEGIN")
  end

  after { conn.exec("ROLLBACK") }

  def differing(original, sqls) = described_class.differing(conn, original, sqls)

  it "names the queries whose rows differ, either way, by their indexes" do
    original = "SELECT d.t.id FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.id FROM d.t WHERE true", "SELECT d.t.id FROM d.t WHERE false",
            "SELECT d.t.id FROM d.t WHERE d.t.id < 3"]

    expect(differing(original, sqls)).to eq([0, 1])
  end

  it "counts a row's copies" do
    original = "SELECT d.t.g FROM d.t WHERE d.t.id <> 2"

    expect(differing(original, ["SELECT d.t.g FROM d.t WHERE true"])).to eq([0])
  end

  it "doesn't count tied rows in another order, under the original's ORDER BY" do
    original = "SELECT d.t.id FROM d.t ORDER BY d.t.g"

    expect(differing(original, ["SELECT d.t.id FROM d.t ORDER BY d.t.g, d.t.id DESC"])).to eq([])
  end

  it "doesn't count float noise the official comparison calls equal" do
    original = "SELECT sum(d.t.f) FROM d.t"
    noise = "SELECT 0.1::float8 + 0.2::float8 + 0.3::float8 - 1e-15::float8 AS sum"

    expect(differing(original, [noise])).to eq([])
  end

  it "compares a column with no equality operator, query by query, with the official comparison" do
    original = "SELECT d.t.j FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.j FROM d.t WHERE true", "SELECT d.t.j FROM d.t WHERE d.t.id < 3"]

    expect(differing(original, sqls)).to eq([0])
  end

  it "doesn't count a query that fails, and still judges the rest" do
    original = "SELECT d.t.id FROM d.t WHERE d.t.g = 1"
    sqls = ["SELECT d.t.id FROM d.t WHERE 1 / (d.t.g - 1) > 0", "SELECT d.t.id FROM d.t WHERE true"]

    expect(differing(original, sqls)).to eq([1])
    expect(conn.exec("SELECT count(*) FROM d.t").getvalue(0, 0)).to eq("3")
  end
end
