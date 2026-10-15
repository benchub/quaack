# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/counterexamples"
require "quaack/enclave/predicate_atoms"

# Task 20261012-4: which untested atoms a counterexample round's fixture
# exercised, once vacuity-guard's, now Counterexamples::Exercised alone.
RSpec.describe Quaack::Enclave::Counterexamples::Exercised, ".atoms" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "fx", name: "orders") }

  before do
    conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.orders (id integer PRIMARY KEY, status text NOT NULL, qty integer)")
  end

  def inserts(*rows) = rows.map { |id, status, qty| "INSERT INTO fx.orders VALUES (#{id}, '#{status}', #{qty})" }

  # The original's atoms, each loosened to TRUE, by index.
  def loosened(sql)
    parse = PgQuery.parse(sql)
    atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: { orders => %w[id status qty] })
    atoms.each_with_index.to_h { |atom, i| [i, Quaack::Enclave::PredicateAtoms.with_true(parse, atom)] }
  end

  def exercised(sql, rows, queries = loosened(sql))
    described_class.atoms(runner, [], sql, queries, inserts: inserts(*rows))
  end

  it "names the atoms whose loosened query returns other rows on the fixture, and only those" do
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open' AND o.qty > 1"

    expect(exercised(sql, [[1, "open", 5], [2, "held", 5]])).to eq([0])
    expect(exercised(sql, [[1, "open", 5], [2, "held", 5], [3, "open", 0]])).to eq([0, 1])
  end

  # The fixture's rows, which fixture-compare loads in each order.
  def fixture(*rows)
    rows.map do |id, status, qty|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: orders, columns: %w[id status qty],
                                                   values: [id.to_s, status, qty.to_s])
    end
  end

  # Loaded hit first, LIMIT 1 returns the hit either way; the reverse load
  # shows the loosened query returning the near miss.
  it "names an atom under an unordered LIMIT 1 whose loosening equal rows hide, by fixture-compare's mismatch" do
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open' LIMIT 1"
    rows = fixture([1, "open", 5], [2, "held", 5])

    expect(described_class.atoms(runner, rows, sql, loosened(sql))).to eq([0])
  end

  it "runs no comparison when the original returns no rows under its OFFSET" do
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open' OFFSET 5"
    allow(Quaack::Enclave::ResultComparison).to receive(:compare_in_load_orders).and_call_original

    expect(exercised(sql, [[1, "open", 5], [2, "held", 5]])).to eq([])
    expect(Quaack::Enclave::ResultComparison).not_to have_received(:compare_in_load_orders)
  end

  it "drops only the atom whose loosened query fails on the fixture" do
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open' AND o.qty > 1"
    queries = loosened(sql).merge(1 => "SELECT o.id FROM fx.orders o WHERE o.status = 'open' AND 1 / 0 > 0")

    expect(exercised(sql, [[1, "open", 5], [2, "held", 5], [3, "open", 0]], queries)).to eq([0])
  end

  it "raises OriginalFailed when the original fails on the fixture" do
    sql = "SELECT o.id FROM fx.orders o WHERE o.qty / 0 > 1 AND o.status = 'open'"

    expect { exercised(sql, [[1, "open", 5]]) }
      .to raise_error(described_class::OriginalFailed) { |e| expect(e.rule).to eq(:query_failed) }
  end

  it "raises a cancel QUAACK didn't send from the original's query as it is" do
    canceled = Object.new
    canceled.define_singleton_method(:with_fixture) do |_rows, **, &block|
      tx = Object.new
      tx.define_singleton_method(:query) do |_sql|
        raise Quaack::Enclave::ArenaRunner::Error.new(:statement_canceled, step: :query, sqlstate: "57014", index: 0),
              cause: nil
      end
      block.call(tx)
    end
    sql = "SELECT o.id FROM fx.orders o WHERE o.status = 'open'"

    expect { described_class.atoms(canceled, [], sql, loosened(sql)) }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e|
        expect([e.class, e.rule]).to eq([Quaack::Enclave::ArenaRunner::Error, :statement_canceled])
      }
  end
end
