# frozen_string_literal: true

require "quaack/enclave/deadline"
require "quaack/enclave/fuzz"

# Task 20261012-4: which of the original's predicate atoms the fuzz search's
# and enumerate's worlds showed both ways (Fuzz::Coverage). An atom counts
# both ways only when the original with it replaced by TRUE, and with it
# replaced by FALSE, each gave a result the official comparison calls a
# mismatch on some compared world. Any other atom is untested, by its
# redacted shape.
RSpec.describe Quaack::Enclave::Fuzz::Coverage do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:fuzz) { Quaack::Enclave::Fuzz }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA s;
      CREATE TABLE s.customers (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE s.orders (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES s.customers,
                             status text NOT NULL CHECK (status IN ('new', 'shipped', 'lost')), total numeric);
    SQL
  end

  def search(original, candidate = original, trials: 150, worlds: 0)
    limit = worlds.positive? ? fuzz::Enumerate::Limit.worlds(worlds) : nil
    fuzz.search(conn, original, candidate, stop: fuzz::StopRule.trials(trials), enumerate: limit)
  end

  def untested(...) = search(...).coverage.untested_shapes

  it "finds every atom of a sound rewrite's original both true and false" do
    results = search("SELECT id FROM s.orders WHERE status = 'shipped' AND total > 100",
                     "SELECT id FROM s.orders WHERE total > 100 AND status = 'shipped'")

    expect(results.fuzz.verdict).to eq(:passed)
    expect(results.coverage).to have_attributes(atoms: 2, untested_shapes: [], untested_atoms: [])
  end

  it "names an atom no world can make true, since a CHECK keeps its value out, and only that one" do
    expect(untested("SELECT id FROM s.orders WHERE status = 'returned' OR total > 100"))
      .to eq(["status = $1"])
  end

  it "names an atom that only ever came out true, since a CHECK keeps every other value out" do
    expect(untested("SELECT id FROM s.orders WHERE total > 100 AND status IN ('new', 'shipped', 'lost')"))
      .to eq(["status IN ($2, $3, $4)"])
  end

  it "finds a join's condition both ways" do
    expect(untested("SELECT o.id FROM s.orders o JOIN s.customers c ON c.id = o.customer_id WHERE o.total > 100"))
      .to eq([])
  end

  it "names a condition a never-true one hides behind AND, since no world showed it mattering" do
    expect(untested("SELECT id FROM s.orders WHERE total > 100 AND status = 'returned'"))
      .to eq(["total > $1", "status = $2"])
  end

  it "gives each untested atom's index and path into the original's parse, for counterexamples and AtomPosition" do
    sql = "SELECT id FROM s.orders WHERE total > 100 OR status = 'returned'"
    coverage = search(sql).coverage

    orders = Quaack::Enclave::TableName.new(schema: "s", name: "orders")
    columns = { orders => %w[id customer_id status total] }
    atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: columns)
    expect(coverage.untested_atoms).to eq([1])
    expect(coverage.untested_paths).to eq([atoms[1].path])
  end

  it "counts enumerate's worlds too" do
    sql = "SELECT id FROM s.orders WHERE status = 'shipped' AND total > 100"
    expect(search(sql, trials: 1, worlds: 0).coverage.untested_shapes).not_to be_empty
    expect(search(sql, trials: 1, worlds: 2000).coverage.untested_shapes).to eq([])
  end

  it "counts a USING column, which can't be replaced, as untested" do
    conn.exec("CREATE TABLE s.notes (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES s.customers)")
    sql = "SELECT n.id FROM s.notes n JOIN s.customers c USING (id)"
    expect(untested(sql)).to eq(["USING (id)"])
  end

  # The 20261011-2 rule: whether a random world reaches past a count
  # threshold follows the literal, so such a query reports every atom
  # untested, whatever the literal.
  it "reports every atom untested, checking none, for a query that compares an aggregate with a constant" do
    sql = "SELECT customer_id FROM s.orders WHERE total > 100 GROUP BY customer_id HAVING count(*) > 0"
    expect(untested(sql)).to eq(["total > $1", "count(*) > $2"])
  end

  it "reports every atom untested for a constant compared with a column over a derived table's aggregate" do
    sql = "SELECT t.k FROM (SELECT customer_id, count(*) AS k FROM s.orders WHERE total > 100 " \
          "GROUP BY customer_id) t WHERE t.k > 0"
    expect(untested(sql)).to eq(["total > $1", "t.k > $2"])
  end

  it "reports every atom untested for a query that calls a volatile function" do
    sql = "SELECT id FROM s.orders WHERE status = 'shipped' AND total > random()"
    expect(untested(sql)).to eq(["status = $1", "total > random()"])
  end

  it "gives no coverage when no search ran" do
    expect(search("SELECT 1 WHERE 1 > 0").coverage).to be_nil
  end
end
