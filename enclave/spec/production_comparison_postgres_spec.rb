# frozen_string_literal: true

require "quaack/enclave/production_comparison"

# README 14c: the original and a candidate run as plain queries on the
# racetrack, streamed and compared by hash with 9d's rules.
RSpec.describe Quaack::Enclave::ProductionComparison do
  let(:conn) { racetrack_and_arena.racetrack.connection }

  def compare(original, candidate, params: [], timeout_ms: 5_000)
    described_class.compare(connection: conn, original:, candidate:, params:, timeout_ms:)
  end

  def verdict(original, candidate, **) = compare(original, candidate, **).then { [it.result, it.rule] }

  it "passes the same rows in another order" do
    expect(verdict("SELECT i FROM generate_series(1, 50) i",
                   "SELECT i FROM generate_series(50, 1, -1) i")).to eq(["pass", nil])
  end

  it "fails different rows with the multiset rule" do
    expect(verdict("SELECT i FROM generate_series(1, 50) i",
                   "SELECT i FROM generate_series(2, 51) i")).to eq(%w[fail multiset])
  end

  it "fails a different multiplicity with the same distinct rows" do
    expect(verdict("SELECT i % 2 FROM generate_series(1, 4) i",
                   "SELECT i % 2 FROM generate_series(1, 4) i WHERE i <> 1 UNION ALL SELECT 0"))
      .to eq(%w[fail multiset])
  end

  it "fails a different row count" do
    expect(verdict("SELECT 1", "SELECT 1 UNION ALL SELECT 1")).to eq(%w[fail row_count])
  end

  it "fails different column types" do
    expect(verdict("SELECT 1::int4", "SELECT 1::int8")).to eq(%w[fail column_types])
  end

  it "rounds floats to 9d's tolerance before hashing" do
    expect(verdict("SELECT 0.3::float8", "SELECT 0.1::float8 + 0.2::float8")).to eq(["pass", nil])
  end

  it "binds params to both queries" do
    expect(verdict("SELECT i FROM generate_series(1, 9) i WHERE i < $1",
                   "SELECT i FROM generate_series(1, 9) i WHERE i < $1 ORDER BY i DESC",
                   params: [{ value: "5", type: 23 }])).to eq(["pass", nil])
  end

  describe "ORDER BY" do
    it "passes the same order" do
      expect(verdict("SELECT i FROM generate_series(1, 20) i ORDER BY i",
                     "SELECT i FROM generate_series(20, 1, -1) i ORDER BY i")).to eq(["pass", nil])
    end

    it "fails another order with the value rule" do
      expect(verdict("SELECT i FROM generate_series(1, 20) i ORDER BY i",
                     "SELECT i FROM generate_series(1, 20) i ORDER BY i DESC")).to eq(%w[fail value])
    end

    it "fails a candidate that drops a sort key, via the tiebreaker" do
      expect(verdict("SELECT i % 3 AS a, i FROM generate_series(1, 9) i ORDER BY a, i",
                     "SELECT i % 3 AS a, i FROM generate_series(1, 9) i ORDER BY a")).to eq(%w[fail value])
    end

    it "binds params in the ordered runs" do
      expect(verdict("SELECT i FROM generate_series(1, 9) i WHERE i < $1 ORDER BY i",
                     "SELECT i FROM generate_series(9, 1, -1) i WHERE i < $1 ORDER BY i",
                     params: [{ value: "5", type: 23 }])).to eq(["pass", nil])
    end

    it "fails a candidate with no ORDER BY" do
      expect(verdict("SELECT 1 ORDER BY 1", "SELECT 1")).to eq(%w[fail candidate_unordered])
    end

    it "refuses an original whose LIMIT cuts a tie group" do
      expect(verdict("SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a LIMIT 3",
                     "SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a LIMIT 3"))
        .to eq(%w[fail unsupported_order])
    end

    it "refuses WITH TIES" do
      expect(verdict("SELECT 1 ORDER BY 1 FETCH FIRST 1 ROWS WITH TIES", "SELECT 1 ORDER BY 1"))
        .to eq(%w[fail unsupported_order])
    end

    it "refuses a cut when a column is left out of the tiebreaker" do
      sql = "SELECT i AS a, '{}'::json AS v FROM generate_series(1, 5) i ORDER BY a LIMIT 2"
      expect(verdict(sql, sql)).to eq(%w[fail unsupported_order])
    end

    it "refuses tied rows that differ in a column left out of the tiebreaker" do
      sql = "SELECT 1 AS a, v FROM (VALUES ('{\"x\":1}'::json), ('{\"x\":2}'::json)) t(v) ORDER BY a"
      expect(verdict(sql, sql)).to eq(%w[fail unsupported_order])
    end
  end

  describe "LIMIT without ORDER BY" do
    it "passes rows drawn from the full result, with the expected count" do
      expect(verdict("SELECT i FROM generate_series(1, 20) i LIMIT 3",
                     "SELECT i FROM generate_series(20, 1, -1) i LIMIT 3")).to eq(["pass", nil])
    end

    it "fails a row that isn't in the full result" do
      expect(verdict("SELECT i FROM generate_series(1, 20) i LIMIT 3",
                     "SELECT i FROM generate_series(19, 21) i")).to eq(%w[fail subset])
    end

    it "fails the wrong count" do
      expect(verdict("SELECT i FROM generate_series(1, 20) i LIMIT 3",
                     "SELECT i FROM generate_series(1, 20) i LIMIT 4")).to eq(%w[fail row_count])
    end

    slow = "SELECT i, pg_sleep(0.01)::text FROM generate_series(1, 1000) i LIMIT 2"

    it "is partial when the full original times out and the count matches" do
      expect(verdict(slow, "SELECT i, ''::text FROM generate_series(-5, -4) i", timeout_ms: 1_000))
        .to eq(%w[partial subset_timed_out])
    end

    it "fails when the full original times out and the count differs" do
      expect(verdict(slow, "SELECT 1, ''::text", timeout_ms: 1_000)).to eq(%w[fail row_count])
    end
  end

  it "fails a candidate that times out" do
    expect(verdict("SELECT 1", "SELECT 1 FROM pg_sleep(2)", timeout_ms: 500)).to eq(%w[fail timed_out])
  end

  it "runs each query read-only, so a candidate can't write" do
    conn.exec("CREATE SEQUENCE read_only_probe")
    expect { compare("SELECT 1::int8", "SELECT nextval('read_only_probe')") }
      .to raise_error(PG::ReadOnlySqlTransaction)
  ensure
    conn.exec("DROP SEQUENCE IF EXISTS read_only_probe")
  end

  it "keeps row values out of the verdict" do
    result = compare("SELECT 'SENTINEL_ROW_VALUE'", "SELECT 'OTHER_SENTINEL_VALUE'")
    expect(result.to_h).to eq(result: "fail", rule: "multiset")
  end
end
