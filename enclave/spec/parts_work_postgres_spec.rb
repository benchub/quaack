# frozen_string_literal: true

require "quaack/enclave/arena_schema"
require "quaack/enclave/arena_fixture"
require "quaack/enclave/scenarios"

# Parts' work, counted rather than timed (task 20261011-13). A group that
# spills tries each later fixture in turn, and each try lifts the group's
# parents from every fixture. The lifted rows once were worked out again
# for every fixture tried, so a scenario with many spilled fixtures cost
# the cube of their number in RowSet#parents_of calls.
RSpec.describe Quaack::Enclave::Scenarios::Parts do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:tables) { %w[p c].map { Quaack::Enclave::TableName.new(schema: "fx", name: it) } }
  let(:schema) do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.p (id integer PRIMARY KEY, code text UNIQUE);
      CREATE TABLE fx.c (id integer PRIMARY KEY, p_id integer REFERENCES fx.p);
    SQL
    Quaack::Enclave::ArenaSchema.load_closure(conn, tables)
  end

  def fixture_row(name, **pairs)
    Quaack::Enclave::ArenaRunner::FixtureRow.new(table: Quaack::Enclave::TableName.new(schema: "fx", name:),
                                                 columns: pairs.keys.map(&:to_s), values: pairs.values)
  end

  # Every group's parent holds the same unique code, so each fits only a
  # fixture of its own.
  def group(key) = [fixture_row("p", id: key.to_s, code: "same"), fixture_row("c", id: key.to_s, p_id: key.to_s)]

  it "lifts each try's parents once per spill, however many fixtures it tries" do
    counts = [10, 20].map do |n|
      calls = 0
      Quaack::Enclave::Scenarios::RowSet.prepend(counter = Module.new do
        define_method(:parents_of) { |rows| (calls += 1) && super(rows) }
      end)
      parts = described_class.new(schema, conn)
      n.times { parts.add([[group(it)].each]) }
      expect(parts.in_order(tables).size).to eq(n)
      counter.send(:remove_method, :parents_of)
      calls
    end
    expect(counts[1]).to be < counts[0] * 5
  end

  # Each fixture's RowSet#parents_of reads the same group, so the group's
  # own keys (Scenarios::Held) are gathered once a try, not once a fixture.
  it "gathers a try's own keys once, however many fixtures it lifts parents from" do
    counts = [10, 20].map do |n|
      built = 0
      allow(Quaack::Enclave::Scenarios::Held).to(receive(:new).and_wrap_original do |o, *a, &b|
        (built += 1) && o.call(*a, &b)
      end)
      parts = described_class.new(schema, conn)
      n.times { parts.add([[group(it)].each]) }
      expect(parts.in_order(tables).size).to eq(n)
      built
    end
    expect(counts[1]).to be < counts[0] * 3
  end
end
