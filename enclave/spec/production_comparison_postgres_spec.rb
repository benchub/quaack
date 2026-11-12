# frozen_string_literal: true

require "quaack/enclave/production_comparison"
require_relative "support/server_clock"
require_relative "support/sent_sql"

# DESIGN.md's result-comparison: the original and a candidate run as plain queries on the
# racetrack, streamed and compared by hash with fixture-compare's rules.
RSpec.describe Quaack::Enclave::ProductionComparison do
  let(:conn) { racetrack_and_arena.racetrack.connection }

  def compare(original, candidate, params: [], timeout_ms: 5_000)
    described_class.compare(connection: conn, original:, candidate:, params:, timeout_ms:)
  end

  # A refusal's reason too (task 20261110-7), after its rule.
  def verdict(original, candidate, **) = compare(original, candidate, **).then { [it.result, it.rule, *it.reason] }

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

    # Any order of the original's tie groups is an answer it could give.
    describe "a candidate that orders the original's ties its own way" do
      let(:series) { "SELECT i % 3 AS a, i % 2 AS b, i FROM generate_series(1, 12) i" }

      it "passes a candidate that adds the key as a tiebreak under a LIMIT" do
        expect(verdict("SELECT 1 AS t, i FROM generate_series(1, 2) i ORDER BY t LIMIT 2",
                       "SELECT 1 AS t, i FROM generate_series(1, 2) i ORDER BY t, i LIMIT 2")).to eq(["pass", nil])
      end

      it "passes a tiebreak over several tie groups, with no LIMIT" do
        expect(verdict("#{series} ORDER BY a", "#{series} ORDER BY a, i DESC")).to eq(["pass", nil])
      end

      it "passes a tiebreak that leaves ties of its own inside the original's" do
        expect(verdict("#{series} ORDER BY a", "#{series} ORDER BY a, b")).to eq(["pass", nil])
      end

      # random() gives each run other keys, so the runs fit the original's
      # groups but don't come back reversed (ten rows a group, so chance
      # can't reverse them).
      it "refuses a candidate whose runs fit but don't show its ties" do
        rows = "SELECT i % 3 AS a, i FROM generate_series(1, 30) i"
        expect(verdict("#{rows} ORDER BY a", "#{rows} ORDER BY a, random()"))
          .to eq(%w[fail unsupported_order unsteady_order])
      end

      # 20261111-185500-1: random() gives each of the original's runs
      # other rows. With no LIMIT or OFFSET, that's no cut's doing.
      it "refuses an original whose runs keep other rows as unstable_original, or cut_tie under a LIMIT" do
        rows = "SELECT i % 3 AS a, random() AS r FROM generate_series(1, 30) i ORDER BY a"
        expect([verdict(rows, rows), verdict("#{rows} LIMIT 3", "#{rows} LIMIT 3")])
          .to eq([%w[fail unsupported_order unstable_original], %w[fail unsupported_order cut_tie]])
      end

      # The tiebreaker picks the DISTINCT ON's row: the least i one way, the
      # greatest the other. That's the pick's doing, not the query's.
      it "refuses a DISTINCT ON original whose runs pick other rows as cut_tie, with no LIMIT" do
        rows = "SELECT DISTINCT ON (a) i % 3 AS a, i FROM generate_series(1, 9) i ORDER BY a"
        expect(verdict(rows, rows)).to eq(%w[fail unsupported_order cut_tie])
      end

      it "fails a row moved to another group with the value rule" do
        expect(verdict("#{series} ORDER BY a", "#{series} ORDER BY CASE WHEN i = 3 THEN 1 ELSE i % 3 END, i"))
          .to eq(%w[fail value])
      end

      it "fails rows that differ, though each group keeps its size, with the value rule" do
        swapped = "SELECT i % 3 AS a, i % 2 AS b, CASE i WHEN 3 THEN 4 WHEN 4 THEN 3 ELSE i END AS i " \
                  "FROM generate_series(1, 12) i ORDER BY a, i"

        expect(verdict("#{series} ORDER BY a", swapped)).to eq(%w[fail value])
      end

      it "still fails a candidate that drops a key the original orders by" do
        expect(verdict("#{series} ORDER BY a, b", "#{series} ORDER BY a")).to eq(%w[fail value])
      end

      it "still fails a candidate that sorts the other way" do
        expect(verdict("#{series} ORDER BY a", "#{series} ORDER BY a DESC, i")).to eq(%w[fail value])
      end

      it "fails another number of rows with the row_count rule" do
        expect(verdict("#{series} ORDER BY a",
                       "SELECT i % 3 AS a, i % 2 AS b, i FROM generate_series(1, 11) i ORDER BY a, i"))
          .to eq(%w[fail row_count])
      end
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

      # 20261004-94: the runs without a LIMIT hold a hash for every row, bounded by the timeout
      # and not by memory, so a row cap refuses a result that's too big.
      it "refuses, rather than hold the rows of a run without a LIMIT past the row cap" do
        candidate = "SELECT i % 2 AS a, i FROM generate_series(9, 1, -1) i ORDER BY a LIMIT 3"
        run = -> { described_class.compare(connection: conn, original:, candidate:, params: [], timeout_ms: 5_000) }

        stub_const("Quaack::Enclave::ProductionComparison::HashedRuns::FULL_RUN_ROW_CAP", 9)
        passed = run.call.then { [it.result, it.rule] }
        stub_const("Quaack::Enclave::ProductionComparison::HashedRuns::FULL_RUN_ROW_CAP", 8)
        refused = run.call.then { [it.result, it.rule, it.reason] }

        expect([passed, refused]).to eq([["pass", nil], %w[fail unsupported_order full_run_too_many_rows]])
        expect([conn.transaction_status, conn.exec("SELECT 1").getvalue(0, 0)]).to eq([PG::PQTRANS_IDLE, "1"])
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
          .to eq(%w[fail unsupported_order cut_tie])
      end

      # The original keeps two of 2, 3, 4, and 5, and 3 and 4 both ways
      # its ties break. The candidate ties every row, and could keep 1.
      it "refuses a candidate that matches a tie cut on both sides of the rows kept" do
        expect(verdict("SELECT i FROM generate_series(1, 6) i ORDER BY i IN (1, 6) OFFSET 1 LIMIT 2",
                       "SELECT i FROM generate_series(1, 6) i ORDER BY i * 0 OFFSET 2 LIMIT 2"))
          .to eq(%w[fail unsupported_order cut_tie])
      end

      it "refuses a candidate with DISTINCT ON" do
        expect(verdict(original, "SELECT DISTINCT ON (a, i) i % 2 AS a, i FROM generate_series(1, 9) i " \
                                 "ORDER BY a, i LIMIT 3")).to eq(%w[fail unsupported_order cut_tie])
      end

      # The runs without a LIMIT are made to outlast the timeout here, as
      # a large table's would.
      it "refuses, rather than failing timed_out, when the runs without its LIMIT time out" do
        slow = SentSql::Slow.new(conn)
        candidate = "SELECT i % 2 AS a, i FROM generate_series(9, 1, -1) i ORDER BY a LIMIT 3"
        result = described_class.compare(connection: slow, original:, candidate:, timeout_ms: 300, params: [])
        expect([result.result, result.rule, result.reason, slow.slowed])
          .to eq(["fail", "unsupported_order", "full_run_timed_out", true])
      end

      it "still fails timed_out when the candidate's own runs time out" do
        expect(verdict(original, "SELECT i % 2 AS a, i FROM generate_series(9, 1, -1) i, pg_sleep(1) " \
                                 "ORDER BY a LIMIT 3", timeout_ms: 300)).to eq(%w[fail timed_out])
      end
    end

    # Pagination as ORMs write it, where the tie groups don't reach the
    # edges of the rows kept: the original's runs through the window, both
    # ways, hold the same rows, so nothing runs without a LIMIT.
    describe "an original with a LIMIT and an OFFSET whose edges no tie reaches" do
      let(:original) { "SELECT i / 10 AS a, i FROM generate_series(0, 199) i ORDER BY a DESC LIMIT 20 OFFSET 40" }
      let(:spy) { SentSql::Recorder.new(conn) }

      def spied(candidate, params: [])
        result = described_class.compare(connection: spy, original:, candidate:, params:, timeout_ms: 5_000)
        [result.result, result.rule]
      end

      it "runs no query without a LIMIT, and still checks the candidate row for row" do
        good = spied("SELECT i / 10 AS a, i FROM generate_series(199, 0, -1) i ORDER BY a DESC LIMIT 20 OFFSET 40")
        bad = spied("SELECT i / 10 AS a, i FROM generate_series(0, 199) i ORDER BY a DESC LIMIT 20 OFFSET 41")
        expect([good, bad, spy.unlimited]).to eq([["pass", nil], %w[fail value], []])
      end

      # The candidate's rows through the end of its window, the first 65,
      # cut the tie group of 130 to 139, but it already fails row for row.
      it "runs none for a candidate that fails row for row, though its own tie crosses an edge" do
        bad = spied("SELECT i / 10 AS a, i FROM generate_series(0, 199) i ORDER BY a DESC LIMIT 20 OFFSET 45")
        expect([bad, spy.unlimited]).to eq([%w[fail value], []])
      end

      # The first tie group holds 200 to 204, and the rest hold ten rows
      # each, so the rows kept span 45 to 64, and a group spans 105 to 114.
      it "runs none for a LIMIT and an OFFSET bound to params" do
        sql = "SELECT i / 10 AS a, i FROM generate_series(0, 204) i ORDER BY a DESC LIMIT $1 OFFSET $2"
        params = [{ value: "20", type: 20 }, { value: "45", type: 20 }]
        result = described_class.compare(connection: spy, original: sql, candidate: sql, params:, timeout_ms: 5_000)
        expect([result.result, result.rule, spy.unlimited]).to eq(["pass", nil, []])
      end
    end

    # 20261004-94: CutTies' check relies on this. A cut query keeps every column in the tiebreaker
    # here, or the comparison refuses before it.
    it "refuses a LIMIT over a column the tiebreaker can't order, before any cut-tie check" do
      sql = "SELECT i / 2 AS a, i, '{\"k\":1}'::json AS doc FROM generate_series(1, 9) i ORDER BY a LIMIT 3"
      expect(verdict(sql, sql)).to eq(%w[fail unsupported_order hidden_tie])
    end

    # 20261004-94: the edge query adds the OFFSET to the LIMIT. It mustn't overflow bigint, and a
    # NULL OFFSET is 0. Groups of ten, so the rows kept cut no tie group, and the edge query runs.
    describe "a LIMIT and an OFFSET whose sum is past bigint" do
      let(:biggest) { "9223372036854775807" }
      let(:from) { "SELECT i / 10 AS a, i FROM generate_series(0, 99) i ORDER BY a DESC" }
      let(:reversed) { "SELECT i / 10 AS a, i FROM generate_series(99, 0, -1) i ORDER BY a DESC" }

      def through(sql, params = [])
        shape = Quaack::Enclave::ResultComparison::Shape.parse(sql, :original)
        conn.exec_params(shape.through_window([1, 2], descending: false), params).ntuples
      end

      it "passes the same query with a constant LIMIT of the biggest bigint" do
        expect(verdict("#{from} LIMIT #{biggest} OFFSET 10", "#{reversed} LIMIT #{biggest} OFFSET 10"))
          .to eq(["pass", nil])
      end

      it "passes the same query with that LIMIT bound to a param" do
        params = [{ value: biggest, type: 20 }]
        expect(verdict("#{from} LIMIT $1 OFFSET 10", "#{reversed} LIMIT $1 OFFSET 10", params:)).to eq(["pass", nil])
      end

      it "passes the biggest bigint as the OFFSET too" do
        params = [{ value: biggest, type: 20 }]
        expect(verdict("#{from} LIMIT 20 OFFSET $1", "#{reversed} LIMIT 20 OFFSET $1", params:)).to eq(["pass", nil])
      end

      it "still fails a candidate that differs, with the row_count rule" do
        expect(verdict("#{from} LIMIT #{biggest} OFFSET 10", "#{reversed} LIMIT #{biggest} OFFSET 11"))
          .to eq(%w[fail row_count])
      end

      it "runs the edge query with the rows through the end of the window" do
        expect([through("#{from} LIMIT #{biggest} OFFSET 10"),
                through("#{from} LIMIT $1 OFFSET $2", [biggest, "3"]),
                through("#{from} LIMIT 20 OFFSET 10"),
                through("#{from} LIMIT $1 OFFSET $2", %w[20 10])]).to eq([100, 100, 30, 30])
      end

      it "gives no limit for LIMIT NULL or LIMIT ALL" do
        expect([through("#{from} LIMIT NULL OFFSET 10"), through("#{from} LIMIT ALL OFFSET 10"),
                through("#{from} LIMIT $1 OFFSET 10", [nil])]).to eq([100, 100, 100])
      end

      it "treats an OFFSET of NULL, constant or bound, as 0" do
        expect([through("#{from} LIMIT 20 OFFSET NULL"), through("#{from} LIMIT 20 OFFSET $1", [nil]),
                through("#{from} LIMIT $1 OFFSET $2", ["20", nil])]).to eq([20, 20, 20])
        expect(verdict("#{from} LIMIT 20 OFFSET $1", "#{reversed} LIMIT 20 OFFSET $1",
                       params: [{ value: nil, type: 20 }])).to eq(["pass", nil])
      end
    end

    # The original's rows are fixed, so the candidate's tiebreaker runs
    # must match row for row, but a candidate with a LIMIT and an OFFSET
    # can keep rows from the middle of its own tie group and still match.
    describe "a candidate whose own tie reaches past the edges of the rows it keeps" do
      # The original keeps b, b however its ties break. The candidate ties
      # a, b, b, and c around the rows it keeps, so it could keep a and b,
      # yet both its tiebreaker runs keep b and b.
      it "refuses a candidate whose own tie reaches past both edges of the rows it keeps" do
        products = "(VALUES ('a', 10), ('b', 10), ('b', 10), ('c', 10), ('d', 5)) p(category, price)"
        expect(verdict("SELECT category, price FROM #{products} ORDER BY price DESC, category LIMIT 2 OFFSET 1",
                       "SELECT category, price FROM #{products} ORDER BY price DESC LIMIT 2 OFFSET 1"))
          .to eq(%w[fail unsupported_order cut_tie])
      end

      # The original always keeps 3. The candidate ties all five, and its
      # runs keep the middle one, 3, both ways, but it could keep any.
      it "refuses a candidate that keeps one row from the middle of its own tie" do
        expect(verdict("SELECT i FROM generate_series(1, 5) i ORDER BY i OFFSET 2 LIMIT 1",
                       "SELECT i FROM generate_series(1, 5) i ORDER BY i * 0 OFFSET 2 LIMIT 1"))
          .to eq(%w[fail unsupported_order cut_tie])
      end
    end

    it "refuses WITH TIES" do
      expect(verdict("SELECT 1 ORDER BY 1 FETCH FIRST 1 ROWS WITH TIES", "SELECT 1 ORDER BY 1"))
        .to eq(%w[fail unsupported_order with_ties])
    end

    it "refuses a cut when a column is left out of the tiebreaker" do
      sql = "SELECT i AS a, '{}'::json AS v FROM generate_series(1, 5) i ORDER BY a LIMIT 2"
      expect(verdict(sql, sql)).to eq(%w[fail unsupported_order hidden_tie])
    end

    it "refuses tied rows that differ in a column left out of the tiebreaker" do
      sql = "SELECT 1 AS a, v FROM (VALUES ('{\"x\":1}'::json), ('{\"x\":2}'::json)) t(v) ORDER BY a"
      expect(verdict(sql, sql)).to eq(%w[fail unsupported_order hidden_tie])
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

  describe "a nondeterministic collation when the original's order is total" do
    before do
      conn.exec(<<~SQL)
        CREATE COLLATION nd_kn (provider = icu, locale = 'und-u-kn-true', deterministic = false);
        CREATE TABLE nd_users (id integer PRIMARY KEY, name text);
        CREATE TABLE nd_enrollments (user_id integer);
        INSERT INTO nd_users VALUES (1, 'b2'), (2, 'B10'), (3, 'a'), (4, 'a'), (5, 'c');
        INSERT INTO nd_enrollments VALUES (1), (2), (3), (4), (5), (5)
      SQL
    end

    after { conn.exec("DROP TABLE nd_users, nd_enrollments; DROP COLLATION nd_kn") }

    let(:original) do
      <<~SQL
        SELECT nd_users.*, name COLLATE public.nd_kn FROM nd_users
        WHERE nd_users.id IN (SELECT user_id FROM nd_enrollments)
        ORDER BY name COLLATE public.nd_kn, nd_users.id LIMIT $1 OFFSET $2
      SQL
    end

    it "passes a candidate with the same rows in the same order" do
      candidate = original.sub("nd_users.id IN (SELECT user_id FROM nd_enrollments)",
                               "EXISTS (SELECT FROM nd_enrollments e WHERE e.user_id = nd_users.id)")

      expect(verdict(original, candidate, params: %w[3 1])).to eq(["pass", nil])
    end

    it "fails a candidate whose rows come back in another order" do
      candidate = original.sub("nd_users.id LIMIT", "nd_users.id DESC LIMIT")

      expect(verdict(original, candidate, params: %w[3 1])).to eq(%w[fail value])
    end

    it "still refuses when the original joins and can repeat the keyed rows" do
      joined = original.sub("FROM nd_users\n", "FROM nd_users JOIN nd_enrollments e ON e.user_id = nd_users.id\n")

      expect(verdict(joined, joined, params: %w[3 1])).to eq(%w[fail unsupported_order nondeterministic_collation])
    end
  end

  # Task 20261111-192302-1: row hashes round floats to eight significant
  # digits, so two floats a last bit apart can hash differently. The
  # verdict stays as it is, but says when the results match with float
  # columns cut to eight significant digits on a shifted grid, so the
  # report can say why.
  describe "float noise" do
    # Adjacent doubles that print to eight significant digits as
    # 1.0000000 and 1.0000001.
    below = "'1.000000050000002'::float8"
    above = "'1.0000000500000021'::float8"

    def noise(original, candidate, **) = compare(original, candidate, **).then { [*verdict_of(it), it.float_noise] }
    def verdict_of(result) = [result.result, result.rule, *result.reason]

    # Counts the queries a compare sends.
    let(:counting) do
      Class.new(SimpleDelegator) do
        def sent = (@sent ||= [])

        def send_query_params(sql, *)
          sent << sql
          super
        end
      end.new(conn)
    end

    it "flags a multiset that differs only across a rounding boundary" do
      expect(noise("SELECT 7 AS k, #{below} AS v, NULL::float8 AS n",
                   "SELECT 7 AS k, #{above} AS v, NULL::float8 AS n"))
        .to eq(["fail", "multiset", true])
    end

    it "flags an ordered value mismatch that's only float noise" do
      rows = ->(v) { "SELECT k, CASE WHEN k = 2 THEN #{v} ELSE k END AS v FROM generate_series(1, 3) k ORDER BY k" }
      expect(noise(rows.call(below), rows.call(above))).to eq(["fail", "value", true])
    end

    # Each run gives every row a value within a 1e-12 of the boundary, so
    # the original's two tiebreaker runs keep other row hashes.
    it "flags an original refused as unstable_original by float noise" do
      rows = "SELECT g, #{below} + (random() - 0.5) * 1e-12 AS v FROM generate_series(1, 20) g ORDER BY g"
      expect(noise(rows, rows)).to eq(["fail", "unsupported_order", "unstable_original", true])
    end

    it "flags a subset mismatch that's only float noise" do
      expect(noise("SELECT v FROM (VALUES (#{below}), (2)) t(v) LIMIT 1", "SELECT #{above} LIMIT 1"))
        .to eq(["fail", "subset", true])
    end

    it "flags an original refused as cut_tie under a LIMIT by float noise" do
      rows = "SELECT g, #{below} + (random() - 0.5) * 1e-12 AS v FROM generate_series(1, 20) g ORDER BY g LIMIT 15"
      expect(noise(rows, rows)).to eq(["fail", "unsupported_order", "cut_tie", true])
    end

    # Task 20261112-000801-1: the second look's grid cuts at eight
    # significant digits, so its boundaries sit on short decimals such as
    # 0.3, where noise fails it about half the time. A result whose rows
    # each match under one look or the other is flagged, though no single
    # look matches every row. 0.3 and 0.1 + 0.2 match under the first.
    describe "across many rows" do
      point_three = "0.3::float8"
      sum_point_three = "(0.1::float8 + 0.2::float8)"
      rows = ->(v, w) { "SELECT 1 AS k, #{v} AS v UNION ALL SELECT 2, #{w}" }

      it "flags a multiset whose rows each match under one look or the other" do
        expect(noise(rows.call(below, point_three), rows.call(above, sum_point_three)))
          .to eq(["fail", "multiset", true])
      end

      it "flags an ordered result whose rows each match under one look or the other at their place" do
        ordered = ->(v, w) { "SELECT * FROM (#{rows.call(v, w)}) r ORDER BY k" }
        expect(noise(ordered.call(below, point_three), ordered.call(above, sum_point_three)))
          .to eq(["fail", "value", true])
      end

      it "doesn't flag an ordered result whose rows match only in another place" do
        ordered = ->(v, w, direction) { "SELECT * FROM (#{rows.call(v, w)}) r ORDER BY k #{direction}" }
        expect(noise(ordered.call(below, point_three, "ASC"), ordered.call(above, sum_point_three, "DESC")))
          .to eq(["fail", "value", false])
      end

      it "flags a subset whose rows each match a row of the full result under one look or the other" do
        full = "SELECT v FROM (VALUES (#{below}), (#{point_three}), (2)) t(v) LIMIT 2"
        expect(noise(full, "SELECT #{above} UNION ALL SELECT #{sum_point_three} LIMIT 2"))
          .to eq(["fail", "subset", true])
      end

      # A float8 sum of cent amounts adds in another order and lands a last
      # bit apart: in one group of these across the first look's grid, in
      # four others across the second's.
      it "flags a GROUP BY sum over float cents added in another order" do
        amounts = "SELECT g / 500 AS u, g AS id, ((hashint4(g) & 2147483647) % 2000000) / 100.0::float8 AS amount " \
                  "FROM generate_series(0, 49999) g"
        query = ->(direction) { "SELECT u, sum(amount ORDER BY id #{direction}) FROM (#{amounts}) a GROUP BY u" }
        expect(noise(query.call("ASC"), query.call("DESC"), timeout_ms: 30_000)).to eq(["fail", "multiset", true])
        expect(noise("#{query.call("ASC")} ORDER BY u", "#{query.call("DESC")} ORDER BY u", timeout_ms: 30_000))
          .to eq(["fail", "value", true])
      end

      # Each run gives half the rows a value within a 1e-12 of the first
      # look's boundary and half within a 1e-12 of the second's.
      jittered = lambda do |cut|
        "SELECT g, CASE WHEN g % 2 = 0 THEN #{below} ELSE #{point_three} END + (random() - 0.5) * 1e-12 AS v " \
          "FROM generate_series(1, 40) g ORDER BY g#{cut}"
      end

      it "flags an original refused as unstable_original by float noise across both grids" do
        expect(noise(jittered.call(""), jittered.call("")))
          .to eq(["fail", "unsupported_order", "unstable_original", true])
      end

      it "flags an original refused as cut_tie under a LIMIT by float noise across both grids" do
        expect(noise(jittered.call(" LIMIT 30"), jittered.call(" LIMIT 30")))
          .to eq(["fail", "unsupported_order", "cut_tie", true])
      end

      # Its runs through the end of the window must hold the same rows too
      # (CutTies.needed?).
      it "flags an original refused as cut_tie under a LIMIT and an OFFSET by float noise across both grids" do
        expect(noise(jittered.call(" LIMIT 20 OFFSET 5"), jittered.call(" LIMIT 20 OFFSET 5")))
          .to eq(["fail", "unsupported_order", "cut_tie", true])
      end

      # Each of the candidate's rows needs a row of the original's of its
      # own that it matches: 1.00000016 matches neither of the original's
      # under either look, though below matches above under the second.
      it "doesn't flag a row whose only partners are another row's" do
        expect(noise("SELECT #{below} UNION ALL SELECT #{below}", "SELECT #{above} UNION ALL SELECT 1.00000016::float8"))
          .to eq(["fail", "multiset", false])
      end
    end

    it "doesn't flag floats that differ plainly" do
      expect(noise("SELECT 7 AS k, 1.0001::float8 AS v", "SELECT 7 AS k, 1.0002::float8 AS v"))
        .to eq(["fail", "multiset", false])
    end

    # Review of 20261111-192302-1: a second look that rounded to five
    # significant digits flagged these.
    it "doesn't flag floats more than a step of eight significant digits apart" do
      expect(noise("SELECT 7 AS k, 1.00000004::float8 AS v", "SELECT 7 AS k, 1.00000016::float8 AS v"))
        .to eq(["fail", "multiset", false])
    end

    it "flags negative float noise, but not a flipped sign" do
      expect(noise("SELECT -#{below}", "SELECT -#{above}")).to eq(["fail", "multiset", true])
      expect(noise("SELECT -#{below}", "SELECT #{below}")).to eq(["fail", "multiset", false])
    end

    it "doesn't flag a rewrite that drops one row from a large float sum or avg" do
      rows = "SELECT g % 5 AS u, g AS id, ((g::bigint * 7919) % 1000) / 7.0::float8 AS score " \
             "FROM generate_series(1, 500000) g"
      %w[sum avg].each do |aggregate|
        query = ->(where) { "SELECT u, #{aggregate}(score) FROM (#{rows}) r #{where} GROUP BY u ORDER BY u" }
        expect(noise(query.call(""), query.call("WHERE id <> 3"), timeout_ms: 30_000))
          .to eq(["fail", "value", false])
      end
    end

    it "doesn't flag float noise when another column differs" do
      expect(noise("SELECT 7 AS k, #{below} AS v", "SELECT 8 AS k, #{above} AS v"))
        .to eq(["fail", "multiset", false])
    end

    it "doesn't flag a row count mismatch" do
      expect(noise("SELECT #{below}", "SELECT #{above} UNION ALL SELECT #{above}"))
        .to eq(["fail", "row_count", false])
    end

    it "doesn't flag a pass" do
      expect(noise("SELECT #{below}", "SELECT #{below}")).to eq(["pass", nil, false])
    end

    it "runs nothing more for a result with no float columns" do
      expect(verdict_of(described_class.compare(connection: counting, original: "SELECT 1.5::numeric",
                                                candidate: "SELECT 1.5000001::numeric", params: [],
                                                timeout_ms: 5_000))).to eq(%w[fail multiset])
      expect(counting.sent.size).to eq(2)
    end

    # Review of 20261111-192302-1: neither failure is one float noise
    # could cause, so neither earns a second look.
    it "runs nothing more for a float result that fails row_count or timed_out" do
      [["SELECT #{below}", "SELECT #{above} UNION ALL SELECT #{above}", %w[fail row_count]],
       ["SELECT #{below}", "SELECT #{above} FROM pg_sleep(2)", %w[fail timed_out]]].each do |original, candidate, rule|
        counting.sent.clear
        expect(verdict_of(described_class.compare(connection: counting, original:, candidate:, params: [],
                                                  timeout_ms: 500))).to eq(rule)
        expect(counting.sent.size).to eq(2)
      end
    end

    # The original sleeps once the server's clock passes a mark that the
    # candidate's sleep carries the first compare past, so only the
    # second look times out.
    it "keeps the verdict, unflagged, when the second look times out" do
      mark = conn.exec("SELECT (clock_timestamp() + interval '300 ms')::text").getvalue(0, 0)
      original = "SELECT #{below} FROM pg_sleep(CASE WHEN clock_timestamp() > '#{mark}' THEN 3 ELSE 0 END)"
      expect(noise(original, "SELECT #{above} FROM pg_sleep(0.6)", timeout_ms: 1_500))
        .to eq(["fail", "multiset", false])
    end
  end

  it "keeps row values out of the verdict" do
    result = compare("SELECT 'SENTINEL_ROW_VALUE'", "SELECT 'OTHER_SENTINEL_VALUE'")
    expect(result.to_h).to eq(result: "fail", rule: "multiset", reason: nil, float_noise: false)
  end

  # Task 20261111-192302-1: float_noise is true or false, and true only on a
  # failing verdict.
  it "refuses a verdict whose float_noise isn't a boolean, or is true on a verdict that didn't fail" do
    sentinel = "SENTINEL_ROW_VALUE"
    [{ result: "fail", rule: "multiset", float_noise: sentinel },
     { result: "fail", rule: "multiset", float_noise: nil },
     { result: "pass", rule: nil, float_noise: true },
     { result: "partial", rule: "subset_timed_out", float_noise: true }].each do |fields|
      expect { described_class::Verdict.new(**fields) }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(sentinel) }
    end
    expect(described_class::Verdict.new(result: "fail", rule: "value", float_noise: true).float_noise).to be(true)
    expect(described_class::Verdict.new(result: "pass", rule: nil).float_noise).to be(false)
  end

  # Task 20261110-7: a refusal's reason is one of Protocol::RefusalReasons,
  # on an unsupported_order verdict only, and never a value.
  it "refuses a verdict whose reason isn't one of QUAACK's own, or doesn't go with its rule" do
    sentinel = "SENTINEL_ROW_VALUE"
    [{ rule: "unsupported_order", reason: sentinel }, { rule: "unsupported_order", reason: nil },
     { rule: "unsupported_order", reason: :cut_tie }, { rule: "value", reason: "cut_tie" },
     { rule: nil, reason: "cut_tie" }].each do |fields|
      expect { described_class::Verdict.new(result: "fail", **fields) }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(sentinel) }
    end
    expect(described_class::Verdict.new(result: "fail", rule: "unsupported_order", reason: "cut_tie").reason)
      .to eq("cut_tie")
    expect(described_class::Verdict.new(result: "pass", rule: nil).reason).to be_nil
  end
end
