# frozen_string_literal: true

require "quaack/enclave/production_comparison"
require_relative "support/server_clock"

# DESIGN.md's result-comparison: the original and a candidate run as plain queries on the
# racetrack, streamed and compared by hash with fixture-compare's rules.
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

  it "rounds floats to fixture-compare's tolerance before hashing" do
    expect(verdict("SELECT 0.3::float8", "SELECT 0.1::float8 + 0.2::float8")).to eq(["pass", nil])
  end

  it "hashes intervals by value, so equal intervals that print differently pass" do
    expect([verdict("SELECT interval '1 day'", "SELECT interval '24 hours'"),
            verdict("SELECT interval '1 day'", "SELECT interval '25 hours'")]).to eq([["pass", nil], %w[fail multiset]])
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

    describe "an original whose LIMIT or OFFSET cuts a tie group" do
      let(:original) { "SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a LIMIT 3" }

      it "passes a candidate that keeps other rows from the tie" do
        expect(verdict(original, "SELECT i % 2 AS a, i FROM generate_series(9, 1, -1) i ORDER BY a LIMIT 3"))
          .to eq(["pass", nil])
      end

      it "fails a row from outside the tie with the value rule" do
        expect(verdict(original, "SELECT i % 2 AS a, i FROM generate_series(1, 9) i UNION ALL SELECT 0, 10 " \
                                 "ORDER BY a LIMIT 3")).to eq(%w[fail value])
      end

      it "fails more of a row than the tie holds with the value rule" do
        expect(verdict(original, "SELECT i % 2 AS a, i FROM generate_series(1, 9) i UNION ALL SELECT 0, 2 " \
                                 "ORDER BY a LIMIT 3")).to eq(%w[fail value])
      end

      it "passes an OFFSET bound to a param that passes every row" do
        sql = "SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a OFFSET $1 LIMIT 2"
        expect(verdict(sql, sql, params: [{ value: "99", type: 23 }])).to eq(["pass", nil])
      end

      it "fails another number of rows with the row_count rule" do
        expect(verdict(original, "SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a LIMIT 2"))
          .to eq(%w[fail row_count])
      end

      it "finds an OFFSET bound to a param" do
        offset = "SELECT i % 2 AS a, i FROM generate_series(1, 9) i ORDER BY a OFFSET $1 LIMIT 2"
        candidate = "SELECT i % 2 AS a, i FROM generate_series(9, 1, -1) i ORDER BY a OFFSET $1 LIMIT 2"
        params = [{ value: "1", type: 23 }]

        expect([verdict(offset, candidate, params:), verdict(offset, candidate.sub("$1", "$1 + 2"), params:)])
          .to eq([["pass", nil], %w[fail value]])
      end

      # 1 and 3 tie in the original, and come before 2. The candidate ties
      # all three, so it could keep 2, though its tiebreaker runs keep 1
      # and 3.
      it "refuses a candidate whose own tie at the cut could keep a row the original's can't" do
        expect(verdict("SELECT i FROM generate_series(1, 3) i ORDER BY i = 2 LIMIT 1",
                       "SELECT i FROM generate_series(1, 3) i ORDER BY i * 0 LIMIT 1"))
          .to eq(%w[fail unsupported_order])
      end

      # The original keeps two of 2, 3, 4, and 5, and 3 and 4 both ways
      # its ties break. The candidate ties every row, and could keep 1.
      it "refuses a candidate that matches a tie cut on both sides of the rows kept" do
        expect(verdict("SELECT i FROM generate_series(1, 6) i ORDER BY i IN (1, 6) OFFSET 1 LIMIT 2",
                       "SELECT i FROM generate_series(1, 6) i ORDER BY i * 0 OFFSET 2 LIMIT 2"))
          .to eq(%w[fail unsupported_order])
      end

      it "refuses a candidate with DISTINCT ON" do
        expect(verdict(original, "SELECT DISTINCT ON (a, i) i % 2 AS a, i FROM generate_series(1, 9) i " \
                                 "ORDER BY a, i LIMIT 3")).to eq(%w[fail unsupported_order])
      end
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

    # Only rows past the LIMIT sleep, so the LIMIT run is instant however
    # loaded the machine is, and the full run takes 1,000 s.
    slow = "SELECT i, pg_sleep(CASE WHEN i > 2 THEN 1 ELSE 0 END)::text FROM generate_series(1, 1002) i LIMIT 2"

    it "is partial when the full original times out and the count matches" do
      expect(verdict(slow, "SELECT i, ''::text FROM generate_series(-5, -4) i", timeout_ms: 1_000))
        .to eq(%w[partial subset_timed_out])
    end

    it "fails when the full original times out and the count differs" do
      expect(verdict(slow, "SELECT 1, ''::text", timeout_ms: 1_000)).to eq(%w[fail row_count])
    end

    it "is partial when the full original times out, even if the enclave's clock runs slower than the server's" do
      slow_enclave_clock
      expect(verdict(slow, "SELECT i, ''::text FROM generate_series(-5, -4) i", timeout_ms: 1_000))
        .to eq(%w[partial subset_timed_out])
    end

    it "fails with timed_out when the original's LIMIT run itself times out" do
      expect(verdict("SELECT i FROM generate_series(1, 2) i, pg_sleep(2) LIMIT 1", "SELECT 1", timeout_ms: 500))
        .to eq(%w[fail timed_out])
    end
  end

  it "fails a candidate that times out" do
    expect(verdict("SELECT 1", "SELECT 1 FROM pg_sleep(2)", timeout_ms: 500)).to eq(%w[fail timed_out])
  end

  it "fails a candidate that times out, even if the enclave's clock runs slower than the server's" do
    slow_enclave_clock
    expect(verdict("SELECT 1", "SELECT 1 FROM pg_sleep(2)", timeout_ms: 500)).to eq(%w[fail timed_out])
  end

  it "raises an operator's cancel instead of counting it as timed out" do
    cancel_when_sleeping(conn) do
      expect { compare("SELECT 1", "SELECT 1 FROM pg_sleep(3)") }.to raise_error(PG::QueryCanceled, /user request/)
    end
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "raises the cancel, not the read's error, when the server's clock can't be read after it" do
    clockless = clockless_after_cancel(conn, "SENTINEL_CLOCK_READ")
    expect do
      described_class.compare(connection: clockless, original: "SELECT 1", candidate: "SELECT 1 FROM pg_sleep(2)",
                              params: [], timeout_ms: 500)
    end.to raise_error(PG::QueryCanceled) { expect(it.message).not_to include("SENTINEL_CLOCK_READ") }
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "raises a bug in reading the server's clock after a cancel, not the cancel" do
    misread = misread_clock(conn, "ROLLBACK TO SAVEPOINT")
    expect do
      described_class.compare(connection: misread, original: "SELECT 1", candidate: "SELECT 1 FROM pg_sleep(2)",
                              params: [], timeout_ms: 500)
    end.to raise_error(ArgumentError, /not a clock/)
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
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
