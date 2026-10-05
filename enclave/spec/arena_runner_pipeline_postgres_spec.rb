# frozen_string_literal: true

require "delegate"
require "quaack/enclave/arena_runner"

RSpec.describe Quaack::Enclave::ArenaRunner::Pipeline do
  let(:conn) { racetrack_and_arena.arena.connection }

  # An error can come after the last statement's result, in the Sync's
  # place, as when statement_timeout fires just as a statement finishes.
  # A deferred foreign key checked at the Sync's implicit commit gives the
  # same sequence every time: the INSERT's result, then the error, then the
  # Sync.
  it "drains an error that comes before the Sync, leaves pipeline mode, and returns it as the last statement's" do
    conn.exec(<<~SQL)
      CREATE TABLE p (id integer PRIMARY KEY);
      CREATE TABLE c (pid integer REFERENCES p DEFERRABLE INITIALLY DEFERRED);
    SQL

    results = described_class.run(conn, [["SELECT 1", []], ["INSERT INTO c VALUES (1)", []]])

    expect(results.map(&:result_status)).to eq([2, 7])
    expect(results.last.error_field(67)).to eq("23503")
    expect([conn.pipeline_status, conn.transaction_status]).to eq([0, 0])
    expect(conn.exec("SELECT count(*) FROM c").getvalue(0, 0)).to eq("0")
  end

  # A connection whose first send fails before it reaches the server, and
  # whose Sync an error comes before, so nothing was sent when the error
  # arrives. It fakes only the edge.
  let(:unsent_class) do
    Class.new(SimpleDelegator) do
      def send_query_params(*) = raise(IOError, "planted send failure")

      def pipeline_sync
        __getobj__.send_query_params("SELECT 1/0", [])
        __getobj__.pipeline_sync
      end
    end
  end

  it "lets the send's own error through when an error comes before the Sync and nothing was sent" do
    expect { described_class.run(unsent_class.new(conn), [["SELECT 1", []]]) }
      .to raise_error(IOError, "planted send failure")
    expect([conn.pipeline_status, conn.transaction_status]).to eq([0, 0])
  end

  # A connection that hands back one planted error result just before the
  # Sync's, as when a cancel arrives after the last statement has failed on
  # its own. It fakes only the edge: every other result is the server's.
  let(:late_error_class) do
    Class.new(SimpleDelegator) do
      def initialize(conn, late)
        super(conn)
        @late = late
        @held = []
      end

      def get_result # rubocop:disable Naming/AccessorMethodName -- PG::Connection's own name
        return @held.shift unless @held.empty?

        result = __getobj__.get_result
        return result unless @late && result&.result_status == 10

        @held = [nil, result]
        @late.tap { @late = nil }
      end
    end
  end

  def canceled_result
    conn.send_query("SELECT pg_cancel_backend(pg_backend_pid()), pg_sleep(5)")
    conn.get_result.tap { conn.get_result }
  end

  it "keeps the last statement's own error when a cancel comes after it, before the Sync" do
    late = canceled_result
    expect(late.error_field(67)).to eq("57014")

    results = described_class.run(late_error_class.new(conn, late), [["SELECT 1", []], ["SELECT 1/0", []]])

    expect(results.map(&:result_status)).to eq([2, 7])
    expect(results.last.error_field(67)).to eq("22012")
    expect([conn.pipeline_status, conn.transaction_status]).to eq([0, 0])
  end
end
