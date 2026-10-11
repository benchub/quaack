# frozen_string_literal: true

require "quaack/enclave/deadline"
require "quaack/enclave/scenario_tests"

# rewrite-test's budget per rewrite (task 20261010-53): a deadline that runs
# out stops ScenarioTests wherever it is, in a Ruby loop or between
# statements, and leaves the arena as it found it.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:sql) { "SELECT o.id FROM fx.orders o WHERE o.status = 'SENTINEL_53' AND o.qty <> 5" }

  before do
    conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.orders (id integer PRIMARY KEY, status text NOT NULL, qty integer)")
  end

  # A clock that reads 0 for its first checks calls, then past any budget.
  def counting_clock(checks)
    calls = 0
    -> { (calls += 1) > checks ? 1_000.0 : 0.0 }
  end

  def run_with(deadline)
    Quaack::Enclave::Deadline.within(deadline) { described_class.run(conn, sql, [sql]) }
  end

  # How many deadline checks one whole test makes, on a clock that never runs out.
  def checks_in_a_run
    calls = 0
    run_with(Quaack::Enclave::Deadline.new(1, clock: -> { (calls += 1) && 0.0 }))
    calls - 1
  end

  it "runs to the end under a budget it doesn't use up" do
    expect(run_with(Quaack::Enclave::Deadline.new(1, clock: -> { 0.0 })).results.first.passed).to be(true)
  end

  it "stops with Expired wherever the budget runs out, and leaves no transaction open and no row behind" do
    total = checks_in_a_run
    expect(total).to be > 10
    [0, 1, total / 3, total / 2, total - 1].uniq.each do |checks|
      deadline = Quaack::Enclave::Deadline.new(1, clock: counting_clock(checks + 1))
      expect { run_with(deadline) }.to raise_error(Quaack::Enclave::Deadline::Expired)
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
      expect(conn.exec("SELECT count(*) FROM fx.orders").getvalue(0, 0)).to eq("0")
    end
  end

  # The statements sent to the arena, as the runner sends each one, in a
  # pipeline of three (ArenaRunner::Pipeline): arm the timeout, run, disarm.
  def spy_statements
    [].tap do |sent|
      allow(conn).to(receive(:send_query_params).and_wrap_original { |m, *a| (sent << a.first) && m.call(*a) })
    end
  end

  it "checks the deadline inside the scenario build's Ruby loops, not only before statements" do
    sent = spy_statements
    # The clock reads once for the deadline, passes the first check, then runs out.
    deadline = Quaack::Enclave::Deadline.new(1, clock: counting_clock(2))
    expect { run_with(deadline) }.to raise_error(Quaack::Enclave::Deadline::Expired)
    expect(sent).to eq([])
  end

  it "checks the deadline before each arena statement, so none runs once it has passed" do
    sent = spy_statements
    deadline = Quaack::Enclave::Deadline.new(1, clock: -> { sent.empty? ? 0.0 : 1_000.0 })
    expect { run_with(deadline) }.to raise_error(Quaack::Enclave::Deadline::Expired)
    expect(sent.size).to eq(3)
  end
end
