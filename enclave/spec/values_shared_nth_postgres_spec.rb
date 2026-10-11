# frozen_string_literal: true

require "quaack/enclave/arena_schema"
require "quaack/enclave/scenarios"

# A key slot over a wide Rails schema holds a column per table (every
# table's root_account_id), and each row of each group asks for the slot's
# value, so working the shared value out again each time cost the square
# of the tables (task 20261011-13). Counted, not timed.
RSpec.describe Quaack::Enclave::Scenarios::Values do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:values) { described_class.new(conn) }
  let(:columns) do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.a (id bigint PRIMARY KEY, root_id integer);
      CREATE TABLE fx.b (id bigint PRIMARY KEY, root_id smallint);
    SQL
    tables = %w[a b].map { Quaack::Enclave::TableName.new(schema: "fx", name: it) }
    schema = Quaack::Enclave::ArenaSchema.load_closure(conn, tables)
    tables.map { [it, schema.column(it, "root_id")] }.freeze
  end

  it "works a slot's shared value out once, however many rows ask" do
    calls = 0
    values.singleton_class.prepend(Module.new { define_method(:nth) { |*a, **k| (calls += 1) && super(*a, **k) } })
    found = Array.new(5) { values.shared_nth(columns, 40_000) }

    expect([found.uniq.size, calls]).to eq([1, 2])
  end
end
