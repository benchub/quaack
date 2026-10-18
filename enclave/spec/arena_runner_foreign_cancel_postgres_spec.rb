# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require_relative "support/stalled_logger"

# Task 20261008-60: a real cancel from a second session, landing on the
# runner's own BEGIN or ROLLBACK, is a statement_canceled on that step, which
# Cancel.foreign? calls foreign, so the step ends rather than recording a
# verdict (20261008-55). StalledLogger holds the backend in the statement's
# log line, so the cancel lands on that statement every time. The :transaction
# step's calls read and set libpq's local state, with nothing for a cancel to
# land on, so it has no case here.
RSpec.describe Quaack::Enclave::ArenaRunner, "against a foreign cancel of its BEGIN or ROLLBACK" do
  # A server of its own, since stalling the logger stalls every backend that
  # logs, and only this one runs with logging_collector on.
  before(:all) { @server = TestPostgres.extra_server(TestPostgres::SERVER_SETTINGS + ["logging_collector=on"]) }
  after(:all) { TestPostgres.remove_server(@server) if @server }

  let(:logger) { StalledLogger.new(@server) }
  let(:conn) do
    PG.connect(host: @server.host, port: @server.port, dbname: "postgres",
               user: TestPostgres::USER, password: TestPostgres::PASSWORD).tap { it.exec("SET log_statement = 'all'") }
  end
  let(:runner) { described_class.new(conn) }

  after do
    logger.resume
    conn.close
  end

  def canceled
    yield
    nil
  rescue described_class::Error => e
    e
  end

  it "ends with a foreign statement_canceled on :begin, and opens no transaction" do
    logger.stall
    canceller = logger.cancel_when_logging(conn.backend_pid, "BEGIN")
    ran = false
    error = canceled { runner.with_fixture { ran = true } }

    expect(StalledLogger::PIPE_WRITE_CHANNELS).to include(canceller.value)
    expect([error&.rule, error&.step, error&.sqlstate]).to eq([:statement_canceled, :begin, "57014"])
    expect([described_class::Cancel.foreign?(error), ran, conn.transaction_status]).to eq([true, false, PG::PQTRANS_IDLE])
  end

  # The cancel lands before ROLLBACK runs, so the transaction is still open,
  # aborted. That's harmless, since a foreign cancel ends the step, and the
  # connection with it.
  it "ends with a foreign statement_canceled on :rollback, after the block's query ran" do
    canceller = nil
    result = nil
    error = canceled do
      runner.with_fixture do |tx|
        result = tx.query("SELECT 1 AS one").rows
        logger.stall
        canceller = logger.cancel_when_logging(conn.backend_pid, "ROLLBACK")
      end
    end

    expect(StalledLogger::PIPE_WRITE_CHANNELS).to include(canceller.value)
    expect([error&.rule, error&.step, error&.sqlstate]).to eq([:statement_canceled, :rollback, "57014"])
    expect([described_class::Cancel.foreign?(error), result, conn.transaction_status])
      .to eq([true, [["1"]], PG::PQTRANS_INERROR])
  end
end
