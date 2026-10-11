# frozen_string_literal: true

require "quaack/enclave/arena_fixture"
require "quaack/enclave/table_name"

# A build uses its rows as Hash keys over and over (Scenarios::RowSet), so a
# row's hash is worked out once, when it's made (task 20261011-13).
RSpec.describe Quaack::Enclave::ArenaRunner::FixtureRow do
  def row(value)
    described_class.new(table: Quaack::Enclave::TableName.new(schema: "fx", name: "t"),
                        columns: %w[id note], values: ["1", value])
  end

  it "hashes alike when equal, and works its hash out only once" do
    first = row("a")
    hashed = 0
    trace = TracePoint.new(:c_call) { |tp| hashed += 1 if tp.method_id == :hash && !tp.self.equal?(first) }
    trace.enable { 10.times { first.hash } }

    expect([first.hash == row("a").hash, first.hash == row("b").hash, first.eql?(row("a")), hashed])
      .to eq([true, false, true, 0])
  end
end
