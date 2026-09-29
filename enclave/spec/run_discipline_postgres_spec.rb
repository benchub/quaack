# frozen_string_literal: true

require "quaack/enclave/run_discipline"

# DESIGN.md 12b: every measurement statement runs alone, in a READ ONLY
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

  it "reports a timeout as timed out even when server messages aren't in English" do
    conn.exec("SET lc_messages = 'de_DE.UTF-8'")
    result = run("SELECT pg_sleep(2)", timeout_ms: 100)
    expect(result.timed_out).to be(true)
  ensure
    conn.exec("RESET lc_messages")
  end

  it "raises an operator's cancel instead of counting it as timed out" do
    other = PG.connect(conn.conninfo_hash.compact.except(:fallback_application_name))
    pid = conn.backend_pid
    canceller = Thread.new do
      sleep 0.3
      other.exec_params("SELECT pg_cancel_backend($1)", [pid])
    end
    expect { run("SELECT pg_sleep(3)") }.to raise_error(PG::QueryCanceled, /user request/)
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  ensure
    canceller&.join
    other&.close
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
