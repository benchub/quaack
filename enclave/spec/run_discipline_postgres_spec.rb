# frozen_string_literal: true

require "quaack/enclave/run_discipline"
require_relative "support/server_clock"

# DESIGN.md's run-discipline: every measurement statement runs alone, in a READ ONLY
# transaction, with statement_timeout at 3x the baseline, clamped to 5s..5min.
RSpec.describe Quaack::Enclave::RunDiscipline do
  let(:conn) { racetrack_and_arena.racetrack.connection }

  describe ".timeout_ms" do
    it "is three times the baseline" do
      expect(described_class.timeout_ms(10_000)).to eq(30_000)
    end

    it "is at least 5 seconds" do
      expect(described_class.timeout_ms(100)).to eq(5_000)
    end

    it "is at most 5 minutes" do
      expect(described_class.timeout_ms(200_000)).to eq(300_000)
    end
  end

  def run(sql, timeout_ms: 5_000, connection: conn)
    described_class.run(connection:, sql:, timeout_ms:)
  end

  it "returns the statement's result" do
    result = run("SELECT 41 + 1")
    expect(result.timed_out).to be(false)
    expect(result.result.getvalue(0, 0)).to eq("42")
  end

  it "passes params as bound values, never in the SQL" do
    result = described_class.run(connection: conn, sql: "SELECT $1::int + 1", params: ["41"], timeout_ms: 5_000)
    expect(result.result.getvalue(0, 0)).to eq("42")
  end

  it "runs the statement inside a READ ONLY transaction" do
    expect(run("SELECT current_setting('transaction_read_only')").result.getvalue(0, 0)).to eq("on")
  end

  it "refuses a write, which READ ONLY forbids, and leaves nothing written" do
    conn.exec("CREATE TABLE rd_t (x int)")
    expect { run("INSERT INTO rd_t VALUES (1)") }.to raise_error(PG::ReadOnlySqlTransaction)
    expect(conn.exec("SELECT count(*) FROM rd_t").getvalue(0, 0)).to eq("0")
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "sets statement_timeout for the statement only" do
    before = conn.exec("SHOW statement_timeout").getvalue(0, 0)
    expect(run("SHOW statement_timeout", timeout_ms: 7_000).result.getvalue(0, 0)).to eq("7s")
    expect(conn.exec("SHOW statement_timeout").getvalue(0, 0)).to eq(before)
  end

  it "reports a statement that hits the timeout as timed out" do
    result = run("SELECT pg_sleep(2)", timeout_ms: 100)
    expect(result.timed_out).to be(true)
    expect(result.result).to be_nil
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "reports a timeout as timed out even if the enclave's clock runs slower than the server's" do
    slow_enclave_clock
    result = run("SELECT pg_sleep(2)", timeout_ms: 500)
    expect([result.timed_out, result.result]).to eq([true, nil])
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "reports a timeout as timed out even when server messages aren't in English" do
    conn.exec("SET lc_messages = 'de_DE.UTF-8'")
    result = run("SELECT pg_sleep(2)", timeout_ms: 100)
    expect(result.timed_out).to be(true)
  ensure
    conn.exec("RESET lc_messages")
  end

  it "raises an operator's cancel instead of counting it as timed out" do
    cancel_when_sleeping(conn) do
      expect { run("SELECT pg_sleep(3)") }.to raise_error(PG::QueryCanceled, /user request/)
    end
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  # A cancel is the timeout only if the server's clock, read again after
  # it, shows the timeout has passed. If that read fails, the cancel isn't
  # counted as the timeout, and it's the cancel that's raised, not the
  # read's error, as ArenaRunner reports it as statement_canceled.
  it "raises the cancel, not the read's error, when the server's clock can't be read after it" do
    clockless = clockless_after_cancel(conn, "SENTINEL_CLOCK_READ")
    expect { run("SELECT pg_sleep(2)", timeout_ms: 100, connection: clockless) }
      .to raise_error(PG::QueryCanceled) { expect(it.message).not_to include("SENTINEL_CLOCK_READ") }
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  # Only a Postgres error from the read counts as a failed read. A bug in
  # the enclave's own code is raised, not passed off as a cancel.
  it "raises a bug in reading the server's clock after a cancel, not the cancel" do
    misread = misread_clock(conn, "ROLLBACK TO SAVEPOINT")
    expect { run("SELECT pg_sleep(2)", timeout_ms: 100, connection: misread) }
      .to raise_error(ArgumentError, /not a clock/)
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "refuses SQL holding more than one statement, so a COMMIT can't end the READ ONLY transaction" do
    conn.exec("CREATE TABLE rd_m (x int)")
    expect { run("COMMIT; INSERT INTO rd_m VALUES (1)") }.to raise_error(PG::SyntaxError, /multiple commands/)
    expect(conn.exec("SELECT count(*) FROM rd_m").getvalue(0, 0)).to eq("0")
  end

  it "runs one statement at a time, never in parallel" do
    other = PG.connect(conn.conninfo_hash.compact.except(:fallback_application_name))
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    [conn, other].map { |c| Thread.new { run("SELECT pg_sleep(0.5)", connection: c) } }.each(&:join)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).to be >= 1.0
  ensure
    other&.close
  end
end
