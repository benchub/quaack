# frozen_string_literal: true

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
end
