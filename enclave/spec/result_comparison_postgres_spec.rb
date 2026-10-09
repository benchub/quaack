# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/or_to_union"
require "quaack/enclave/table_name"

# fixture-compare against a real arena: load a fixture with ArenaRunner, run the
# original and a candidate, and compare them under each ordering rule.
# Records the ordered queries a transaction runs without a LIMIT.
class SentQueries < SimpleDelegator
  def unlimited = (@unlimited ||= [])

  def query(sql)
    select = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt
    unlimited << sql if select && !select.sort_clause.empty? && select.limit_count.nil?
    super
  end
end

RSpec.describe Quaack::Enclave::ResultComparison do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }
  let(:sentinel) { "SENTINEL-2b8e61" }

  before do
    conn.exec(<<~SQL)
      CREATE TYPE mood AS ENUM ('sad', 'happy');
      CREATE TYPE pair AS (a integer, b text);
      CREATE TYPE json_pair AS (a integer, b json);
      CREATE TYPE mood_pair AS (a integer, m mood);
      CREATE TYPE npair AS (a integer, n numeric);
      CREATE TYPE ipair AS (a integer, i interval);
      CREATE TABLE items (
        id integer PRIMARY KEY,
        grp integer NOT NULL,
        price float8,
        amount numeric,
        label text,
        doc json,
        m mood,
        p pair,
        jp json_pair,
        mp mood_pair,
        iv interval,
        jb jsonb,
        c bpchar,
        na numeric[],
        np npair,
        ip ipair
      )
    SQL
  end

  def rows_of(columns, *rows)
    rows.map do |values|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns:, values: values.map { |value| value&.to_s })
    end
  end

  # Six rows or fewer, so Postgres sorts them with its stable insertion
  # sort and ties keep their input order. grp ties three ways. The prices
  # sum to 0.6000000000000001 forward and 0.6 in reverse.
  let(:fixture) do
    [
      [1, 1, "0.1", "1.5", "a"],
      [2, 1, "0.2", "2.50", "b"],
      [3, 1, "0.3", "3", "c"],
      [4, 2, nil, "4.25", "d"],
      [5, 3, nil, "5", "e"]
    ].map do |id, grp, price, amount, label|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(
        table: items, columns: %w[id grp price amount label doc],
        values: [id.to_s, grp.to_s, price, amount, label, %({"k": #{id}})]
      )
    end
  end

  def compare(original, candidate, rows: fixture)
    runner.with_fixture(rows) { |tx| described_class.compare(tx, original:, candidate:) }
  end

  # Runs each query as written, for the preconditions that show a rule is
  # needed at all.
  def raw(*queries, rows: fixture)
    runner.with_fixture(rows) { |tx| queries.map { |sql| tx.query(sql).rows } }
  end

  def fields(verdict) = verdict.to_h.slice(:match, :mode, :rule, :row, :column)

  # Scans items in reverse id order, so tied rows reach the sort reversed.
  let(:reversed) { "(SELECT * FROM items ORDER BY id DESC OFFSET 0) items" }
  let(:forward) { "(SELECT * FROM items ORDER BY id OFFSET 0) items" }

  describe "no ORDER BY" do
    it "matches the same rows in another order" do
      original = "SELECT grp, count(*) FROM items GROUP BY grp"
      candidate = "SELECT grp, count(*) FROM items GROUP BY grp ORDER BY grp DESC"

      expect(fields(compare(original, candidate))).to eq(match: true, mode: :multiset, rule: nil, row: nil, column: nil)
    end

    it "is a mismatch for different rows" do
      verdict = compare("SELECT id, label FROM items", "SELECT id, upper(label) FROM items")

      expect(fields(verdict)).to include(match: false, mode: :multiset, rule: :multiset)
    end

    it "is a column_types mismatch for int4 against int8" do
      verdict = compare("SELECT id FROM items", "SELECT id::int8 FROM items")

      expect(fields(verdict)).to include(match: false, rule: :column_types, column: 0)
    end
  end

  describe "an ORDER BY that isn't a total order" do
    let(:original) { "SELECT id, grp FROM #{forward} ORDER BY grp" }

    it "adds a tiebreaker to both queries, so ties in another order still match" do
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp"
      expect(raw(original, candidate).uniq.size).to eq(2)

      expect(fields(compare(original, candidate))).to eq(match: true, mode: :ordered, rule: nil, row: nil, column: nil)
    end

    it "keeps the LIMIT, and matches when it cuts no tie" do
      limited = "#{original} LIMIT 4"
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 4"
      expect(raw(limited, candidate).uniq.size).to eq(2)

      expect(fields(compare(limited, candidate))).to include(match: true, mode: :ordered)
    end

    it "matches a good candidate when the LIMIT splits a tie" do
      limited = "#{original} LIMIT 2"
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 2"
      first, second = raw(limited, candidate)
      expect(first.sort).not_to eq(second.sort)

      expect(fields(compare(limited, candidate))).to include(match: true, rule: nil)
    end

    it "keeps the OFFSET" do
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 1 OFFSET 3"

      expect(compare("#{original} LIMIT 1 OFFSET 3", candidate).match?).to be(true)
      expect(fields(compare("#{original} LIMIT 1 OFFSET 4", candidate))).to include(match: false, rule: :value)
    end

    it "is a value mismatch when the order differs" do
      verdict = compare(original, "SELECT id, grp FROM items ORDER BY grp DESC")

      expect(fields(verdict)).to include(match: false, mode: :ordered, rule: :value, row: 0)
    end

    it "is a candidate_unordered mismatch when the candidate drops the ORDER BY" do
      verdict = compare(original, "SELECT id, grp FROM items")

      expect(fields(verdict)).to eq(match: false, mode: :ordered, rule: :candidate_unordered, row: nil, column: nil)
    end

    it "is a column_types mismatch before any tiebreaker runs" do
      verdict = compare(original, "SELECT id, doc FROM items ORDER BY grp")

      expect(fields(verdict)).to include(match: false, rule: :column_types, column: 1)
    end

    describe "a candidate that leaves rows tied that the original orders" do
      # (id, grp) interleaved, so that ORDER BY grp alone leaves ties the
      # original's ORDER BY grp, id breaks.
      let(:interleaved) do
        [[1, 2], [2, 1], [3, 2], [4, 1], [5, 3]].map do |id, grp|
          Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp], values: [id.to_s, grp.to_s])
        end
      end

      def expect_mismatch(original, candidate)
        verdict = compare(original, candidate, rows: interleaved)

        expect(fields(verdict)).to include(match: false, mode: :ordered, rule: :value)
      end

      it "is a mismatch when the candidate drops a sort key" do
        original = "SELECT id, grp FROM items ORDER BY grp, id"
        candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp"
        expect(raw(original, candidate, rows: interleaved).uniq.size).to eq(2)

        expect_mismatch(original, candidate)
      end

      # Here the descending run matches, so only the ascending one catches it.
      it "is a mismatch when the dropped sort key was descending" do
        expect_mismatch("SELECT id, grp FROM items ORDER BY grp, id DESC",
                        "SELECT id, grp FROM #{forward} ORDER BY grp")
      end

      it "is a mismatch when the candidate's keys tie every row under a LIMIT" do
        expect_mismatch("SELECT id, grp FROM items ORDER BY id LIMIT 2",
                        "SELECT id, grp FROM #{reversed} ORDER BY grp - grp LIMIT 2")
      end

      it "is a mismatch when DISTINCT ON picks by a key the candidate dropped" do
        expect_mismatch("SELECT DISTINCT ON (grp) grp, id FROM items ORDER BY grp, id",
                        "SELECT DISTINCT ON (grp) grp, id FROM #{reversed} ORDER BY grp")
      end

      it "still matches DISTINCT ON when the candidate keeps the keys" do
        verdict = compare("SELECT DISTINCT ON (grp) grp, id FROM #{forward} ORDER BY grp, id",
                          "SELECT DISTINCT ON (grp) grp, id FROM #{reversed} ORDER BY grp, id", rows: interleaved)

        expect(verdict.match?).to be(true)
      end
    end

    # The original's rows depend on how a tie at a LIMIT or OFFSET cut
    # breaks. The rows before the tie must match, in order, and the rest
    # must come from the tie (CutTies), whichever way each query's ties
    # break. A DISTINCT ON pick from a tie is refused.
    describe "a tie at a cut" do
      # Reads items with the given id first, then by id.
      def moved(id) = "(SELECT * FROM items ORDER BY id = #{id} DESC, id OFFSET 0) s"

      def expect_refused(original, candidate, rows)
        expect(fields(compare(original, candidate, rows:)))
          .to eq(match: false, mode: :ordered, rule: :unsupported_order, row: nil, column: nil)
      end

      def expect_matched(original, candidate, rows)
        expect(fields(compare(original, candidate, rows:)))
          .to eq(match: true, mode: :ordered, rule: nil, row: nil, column: nil)
      end

      let(:four) { rows_of(%w[id grp], [1, 0], [2, 1], [3, 2], [4, 1]) }

      # The ordered queries run without a LIMIT.
      def unlimited(original, candidate, rows)
        runner.with_fixture(rows) do |tx|
          spy = SentQueries.new(tx)
          [fields(described_class.compare(spy, original:, candidate:)), spy.unlimited]
        end
      end

      it "runs nothing without a LIMIT when a LIMIT and an OFFSET keep a whole tie group" do
        original = "SELECT id, grp FROM items ORDER BY grp OFFSET 1 LIMIT 3"
        candidate = "SELECT id, grp FROM #{moved(4)} ORDER BY grp OFFSET 1 LIMIT 3"
        wrong = "SELECT id, grp FROM items ORDER BY grp OFFSET 2 LIMIT 3"
        expect([unlimited(original, candidate, five), unlimited(original, wrong, five).first])
          .to eq([[{ match: true, mode: :ordered, rule: nil, row: nil, column: nil }, []],
                  { match: false, mode: :ordered, rule: :value, row: 0, column: 0 }])
      end
      let(:five) { rows_of(%w[id grp], [1, 0], [2, 1], [3, 1], [4, 1], [5, 2]) }

      # The original keeps b, b however its ties break. The candidate ties
      # a, b, b, and c around the rows it keeps, so it can keep a and b, as
      # it does here, yet both its tiebreaker runs keep b and b.
      it "refuses a candidate whose own tie reaches past both edges of the rows it keeps" do
        rows = rows_of(%w[id label grp], [1, "a", 10], [2, "b", 10], [3, "b", 10], [4, "c", 10], [5, "d", 5])
        original = "SELECT label, grp FROM items ORDER BY grp DESC, label LIMIT 2 OFFSET 1"
        candidate = "SELECT label, grp FROM (SELECT * FROM items ORDER BY label <> 'c', label OFFSET 0) s " \
                    "ORDER BY grp DESC LIMIT 2 OFFSET 1"
        expect(raw(original, candidate, rows:)).to eq([[%w[b 10], %w[b 10]], [%w[a 10], %w[b 10]]])

        expect_refused(original, candidate, rows)
      end

      # The candidate drops id, so its tie of 2, 3, and 4 crosses both
      # edges of the rows it keeps, and its descending run keeps 4.
      it "runs nothing without a LIMIT for a candidate that fails row for row, though its own tie crosses an edge" do
        expect(unlimited("SELECT id, grp FROM items ORDER BY grp, id OFFSET 1 LIMIT 2",
                         "SELECT id, grp FROM items ORDER BY grp OFFSET 1 LIMIT 2", five))
          .to eq([{ match: false, mode: :ordered, rule: :value, row: 0, column: 0 }, []])
      end

      it "matches a candidate that keeps another row from the tie at a LIMIT" do
        original = "SELECT id, grp FROM items ORDER BY grp LIMIT 2"
        candidate = "SELECT id, grp FROM #{moved(4)} ORDER BY grp LIMIT 2"
        expect(raw(original, candidate, rows: four)).to eq([[%w[1 0], %w[2 1]], [%w[1 0], %w[4 1]]])

        expect_matched(original, candidate, four)
      end

      it "matches a candidate that keeps other rows from the tie at an OFFSET" do
        original = "SELECT id, grp FROM items ORDER BY grp OFFSET 2"
        candidate = "SELECT id, grp FROM items ORDER BY grp, id DESC OFFSET 2"
        expect(raw(original, candidate, rows: five)).to eq([[%w[3 1], %w[4 1], %w[5 2]], [%w[3 1], %w[2 1], %w[5 2]]])

        expect_matched(original, candidate, five)
      end

      it "is a value mismatch for a wrong row before the tie" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 2",
                          "SELECT id, grp FROM items WHERE id <> 1 ORDER BY grp LIMIT 2", rows: four)

        expect(fields(verdict)).to eq(match: false, mode: :ordered, rule: :value, row: 0, column: nil)
      end

      it "is a value mismatch for a row from outside the tie" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 2",
                          "SELECT id, grp FROM items WHERE grp <> 1 ORDER BY grp LIMIT 2", rows: four)

        expect(fields(verdict)).to eq(match: false, mode: :ordered, rule: :value, row: 1, column: nil)
      end

      it "is a value mismatch for more of a row than the tie holds" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 3",
                          "SELECT id, grp FROM items UNION ALL SELECT 2, 1 ORDER BY grp LIMIT 3", rows: five)

        expect(fields(verdict)).to eq(match: false, mode: :ordered, rule: :value, row: 1, column: nil)
      end

      it "is a value mismatch for the right rows in the wrong order" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 2",
                          "SELECT id, grp FROM items ORDER BY grp DESC OFFSET 2", rows: four)

        expect(fields(verdict)).to include(match: false, rule: :value, row: 0)
      end

      it "is a row_count mismatch when the candidate keeps more rows" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 2",
                          "SELECT id, grp FROM items ORDER BY grp LIMIT 3", rows: four)

        expect(fields(verdict)).to include(match: false, rule: :row_count)
      end

      it "checks every sort key, with its direction and NULLS placement" do
        rows = rows_of(%w[id grp price], [1, 1, nil], [2, 1, nil], [3, 1, 5], [4, 2, 1])
        original = "SELECT id, grp, price FROM items ORDER BY grp DESC, price NULLS FIRST LIMIT 2"
        candidate = "SELECT id, grp, price FROM #{moved(2)} ORDER BY grp DESC, price NULLS FIRST LIMIT 2"
        expect(raw(original, candidate, rows:)).to eq([[%w[4 2 1], ["1", "1", nil]], [%w[4 2 1], ["2", "1", nil]]])

        expect_matched(original, candidate, rows)
        expect(fields(compare(original, "SELECT id, grp, price FROM items ORDER BY grp DESC, price LIMIT 2", rows:)))
          .to eq(match: false, mode: :ordered, rule: :value, row: 1, column: nil)
      end

      it "finds an OFFSET it can't read where only one place fits" do
        original = "SELECT id, grp FROM items ORDER BY grp OFFSET (SELECT 1) LIMIT 1"

        expect_matched(original, "SELECT id, grp FROM #{moved(4)} ORDER BY grp OFFSET 1 LIMIT 1", four)
        expect(fields(compare(original, "SELECT id, grp FROM items ORDER BY grp OFFSET 3 LIMIT 1", rows: four)))
          .to eq(match: false, mode: :ordered, rule: :value, row: 0, column: nil)
      end

      it "matches when an OFFSET it can't read passes every row" do
        sql = "SELECT id, grp FROM items ORDER BY grp OFFSET (SELECT 9) LIMIT 1"
        expect(raw(sql, rows: four)).to eq([[]])

        expect_matched(sql, sql, four)
      end

      # The tiebreaker runs can check a candidate with DISTINCT ON when no
      # tie is cut, and CutTies' can't.
      it "checks an OFFSET with no LIMIT with the tiebreaker runs alone" do
        expect_matched("SELECT id, grp FROM items ORDER BY grp, id OFFSET 1",
                       "SELECT DISTINCT ON (grp, id) id, grp FROM items ORDER BY grp, id OFFSET 1", four)
      end

      it "refuses an OFFSET it can't read when more than one place fits" do
        rows = rows_of(%w[id grp label], [1, 1, "p"], [2, 1, "q"], [3, 2, "p"], [4, 2, "q"])
        candidate = "SELECT label FROM #{moved(2)} ORDER BY grp OFFSET 1 LIMIT 1"

        expect_matched("SELECT label FROM items ORDER BY grp OFFSET 1 LIMIT 1", candidate, rows)
        expect_matched("SELECT label FROM items ORDER BY grp LIMIT 1",
                       "SELECT label FROM #{moved(2)} ORDER BY grp LIMIT 1", rows)
        expect_refused("SELECT label FROM items ORDER BY grp OFFSET (SELECT 1) LIMIT 1", candidate, rows)
        expect_refused("SELECT label FROM items ORDER BY grp OFFSET 1 LIMIT 1",
                       candidate.sub("1 LIMIT", "(SELECT 1) LIMIT"), rows)
      end

      # The original keeps two of 2, 3, 4, and 5, so its two tiebreaker
      # runs keep 3 and 4 both ways. The candidate ties every row, and its
      # runs keep 3 and 4 too, but as written it keeps 1 and 6.
      it "refuses a candidate that matches a tie cut on both sides of the rows kept" do
        original = "SELECT i FROM generate_series(1, 6) i ORDER BY i IN (1, 6) OFFSET 1 LIMIT 2"
        candidate = "SELECT i FROM unnest(ARRAY[2, 3, 1, 6, 4, 5]) i ORDER BY i * 0 OFFSET 2 LIMIT 2"
        expect(raw(original, candidate)).to eq([[%w[3], %w[4]], [%w[1], %w[6]]])

        expect_refused(original, candidate, fixture)
        expect_matched(original, "SELECT i FROM generate_series(6, 1, -1) i ORDER BY i IN (1, 6) OFFSET 1 LIMIT 2",
                       fixture)
      end

      # The candidate ties 2, 3, and 4, so its LIMIT could keep 3, which
      # the original never keeps. Its two tiebreaker runs keep 2 and 4,
      # rows the original could keep, and 3 shows only as written.
      it "refuses a candidate whose own tie at the cut could keep a row the original's can't" do
        original = "SELECT id, grp FROM items ORDER BY grp LIMIT 2"
        candidate = "SELECT id, grp FROM #{moved(3)} ORDER BY LEAST(grp, 1) LIMIT 2"
        expect(raw(candidate, rows: four)).to eq([[%w[1 0], %w[3 2]]])

        expect_refused(original, candidate, four)
      end

      it "refuses the same hole at an OFFSET" do
        rows = rows_of(%w[id grp], [1, 0], [2, 1], [3, 2], [4, 1], [5, 3])

        candidate = "SELECT id, grp FROM #{moved(3)} ORDER BY CASE WHEN grp = 2 THEN 1 ELSE grp END OFFSET 1 LIMIT 1"

        expect_refused("SELECT id, grp FROM items ORDER BY grp OFFSET 1 LIMIT 1", candidate, rows)
      end

      # The candidate ties all three rows, so it could keep 1 and 3, but
      # the original always keeps 2 second.
      it "refuses a candidate whose tie at the cut spans two of the original's" do
        rows = rows_of(%w[id grp], [1, 1], [2, 2], [3, 1])
        original = "SELECT id, grp FROM items ORDER BY grp OFFSET 1 LIMIT 2"
        expect(raw(original, "SELECT id, grp FROM #{moved(3)} ORDER BY grp * 0 LIMIT 2", rows:))
          .to eq([[%w[3 1], %w[2 2]], [%w[3 1], %w[1 1]]])

        expect_refused(original, "SELECT id, grp FROM items ORDER BY grp * 0 LIMIT 2", rows)
      end

      it "refuses a DISTINCT ON whose pick is a tie" do
        rows = rows_of(%w[id grp price], [1, 1, 1], [2, 1, 2], [3, 1, 1])

        expect_refused("SELECT DISTINCT ON (grp) grp, id FROM items ORDER BY grp, price",
                       "SELECT DISTINCT ON (grp) grp, id FROM #{moved(2)} ORDER BY grp, LEAST(price, 1)", rows)
      end

      it "refuses a candidate with DISTINCT ON when the original's LIMIT cuts a tie" do
        expect_refused("SELECT id, grp FROM items ORDER BY grp LIMIT 2",
                       "SELECT DISTINCT ON (grp, id) id, grp FROM items ORDER BY grp, id LIMIT 2", four)
      end

      it "still matches a LIMIT that cuts no tie" do
        verdicts = [1, 3].map do |limit|
          compare("SELECT id, grp FROM #{forward} ORDER BY grp LIMIT #{limit}",
                  "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT #{limit}", rows: four)
        end

        expect(verdicts.map { |v| fields(v) }.uniq)
          .to eq([{ match: true, mode: :ordered, rule: nil, row: nil, column: nil }])
      end

      it "still finds a bad candidate when no tie is cut" do
        verdict = compare("SELECT id, grp FROM items ORDER BY grp LIMIT 3",
                          "SELECT id, grp FROM items ORDER BY grp DESC LIMIT 3", rows: four)

        expect(fields(verdict)).to include(match: false, rule: :value)
      end
    end

    # Each original sorts by a column only the catalog knows can be ordered,
    # and each candidate leaves every row tied, so it comes out in the
    # original's order only by luck of the scan.
    describe "types found in the catalog" do
      it "puts an enum in the tiebreaker" do
        rows = rows_of(%w[id grp m], [1, 1, "sad"], [2, 1, "happy"])
        original = "SELECT m FROM items ORDER BY m"
        candidate = "SELECT m FROM #{forward} ORDER BY grp"
        expect(raw(original, candidate, rows:).uniq.size).to eq(1)

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end

      it "puts an array of enums in the tiebreaker" do
        rows = rows_of(%w[id grp m], [1, 1, "sad"], [2, 1, "happy"])
        original = "SELECT ARRAY[m] AS ms FROM items ORDER BY ms"
        candidate = "SELECT ARRAY[m] AS ms FROM #{forward} ORDER BY grp"
        expect(raw(original, candidate, rows:).uniq.size).to eq(1)

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end

      it "puts a range in the tiebreaker" do
        rows = rows_of(%w[id grp], [1, 1], [2, 1])
        original = "SELECT int4range(0, id) AS r FROM items ORDER BY r"
        candidate = "SELECT int4range(0, id) AS r FROM #{forward} ORDER BY grp"
        expect(raw(original, candidate, rows:).uniq.size).to eq(1)

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end

      it "puts a composite of orderable fields in the tiebreaker" do
        rows = rows_of(%w[id grp p], [1, 1, "(1,a)"], [2, 1, "(1,b)"])
        original = "SELECT p FROM items ORDER BY p"
        candidate = "SELECT p FROM #{forward} ORDER BY grp"
        expect(raw(original, candidate, rows:).uniq.size).to eq(1)

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end

      it "leaves out a composite with a field btree can't order, which ORDER BY would refuse" do
        expect { conn.exec("SELECT NULL::json_pair ORDER BY 1") }.to raise_error(PG::UndefinedFunction)
        rows = rows_of(%w[id grp jp], [1, 1, %((1,"{}"))], [2, 1, %((2,"[]"))])
        sql = "SELECT jp, id FROM #{forward} ORDER BY grp"

        expect(compare(sql, "SELECT jp, id FROM #{reversed} ORDER BY grp", rows:).match?).to be(true)
      end

      it "puts a composite with an enum field in the tiebreaker" do
        rows = rows_of(%w[id grp mp], [1, 1, "(1,sad)"], [2, 1, "(1,happy)"])
        original = "SELECT mp FROM items ORDER BY mp"
        candidate = "SELECT mp FROM #{forward} ORDER BY grp"
        expect(raw(original, candidate, rows:).uniq.size).to eq(1)

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end

      it "reads past a composite's dropped field" do
        conn.exec("ALTER TYPE pair ADD ATTRIBUTE gone json; ALTER TYPE pair DROP ATTRIBUTE gone")
        rows = rows_of(%w[id grp p], [1, 1, "(1,a)"], [2, 1, "(1,b)"])

        expect(fields(compare("SELECT p FROM items ORDER BY p", "SELECT p FROM #{forward} ORDER BY grp", rows:)))
          .to include(match: false, rule: :value)
      end
    end

    # The comparator reads an interval column by value, as interval's own
    # btree does, so '1 day' and '24 hours' are one value however a tie
    # between them comes back, and interval goes in the tiebreaker.
    describe "interval columns" do
      let(:equal_pair) { rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"]) }

      it "matches a tie between equal intervals that print differently, whichever way it comes back" do
        original = "SELECT iv FROM items ORDER BY grp, id"
        candidate = "SELECT iv FROM #{reversed} ORDER BY grp"
        expect(raw(original, candidate, rows: equal_pair)).to eq([[["1 day"], ["24:00:00"]], [["24:00:00"], ["1 day"]]])

        expect(fields(compare(original, candidate, rows: equal_pair)))
          .to eq(match: true, mode: :ordered, rule: nil, row: nil, column: nil)
      end

      it "matches a LIMIT that keeps either of two equal intervals" do
        verdicts = [forward, reversed].map do |from|
          compare("SELECT iv FROM items ORDER BY grp, id LIMIT 1", "SELECT iv FROM #{from} ORDER BY grp LIMIT 1",
                  rows: equal_pair)
        end

        expect(verdicts.map { |v| fields(v) }.uniq).to eq([{ match: true, mode: :ordered, rule: nil, row: nil,
                                                             column: nil }])
      end

      it "is a value mismatch for an interval that isn't equal" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "25 hours"])

        verdict = compare("SELECT iv FROM items ORDER BY grp, id LIMIT 1",
                          "SELECT iv FROM items ORDER BY grp, id DESC LIMIT 1", rows:)

        expect(fields(verdict)).to include(match: false, rule: :value, row: 0, column: 0)
      end

      it "puts interval in the tiebreaker, so a candidate that drops it as a key is caught" do
        rows = rows_of(%w[id grp iv], [1, 1, "2 days"], [2, 1, "1 day"])
        original = "SELECT iv FROM items ORDER BY iv"
        candidate = "SELECT iv FROM #{reversed} ORDER BY grp"
        expect(raw(original, rows:)).to eq([[["1 day"], ["2 days"]]])

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :value)
      end
    end

    # btree calls these values equal, but they print differently, so a
    # tiebreaker can't split them and the comparator would see them differ.
    describe "types whose equal values print differently" do
      it "refuses a jsonb column in a tie, since the tie can come back either way" do
        rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'])
        original = "SELECT jb FROM items ORDER BY grp, id"
        candidate = "SELECT jb FROM #{forward} ORDER BY grp"
        forward_rows, reversed_rows = raw(candidate, "SELECT jb FROM #{reversed} ORDER BY grp", rows:)
        expect([forward_rows == raw(original, rows:).first, forward_rows == reversed_rows]).to eq([true, false])

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :unsupported_order)
      end

      it "refuses a jsonb column under a LIMIT" do
        rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'])

        verdict = compare("SELECT jb FROM items ORDER BY grp, id LIMIT 1",
                          "SELECT jb FROM #{forward} ORDER BY grp LIMIT 1", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "refuses a jsonb column when only the original has a LIMIT" do
        rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'])

        verdict = compare("SELECT jb FROM items ORDER BY grp LIMIT 1",
                          "SELECT jb FROM items WHERE id = 1 ORDER BY grp", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      # The odd value sits after a repeat, and then between repeats, so
      # checking only the first two rows, or only the first and last, of a
      # tie misses it in one fixture or the other.
      [
        ['{"a": 1.0}', '{"a": 1.0}', '{"a": 1.00}'],
        ['{"a": 1.0}', '{"a": 1.0}', '{"a": 1.00}', '{"a": 1.0}']
      ].each do |docs|
        it "refuses a jsonb column when a tie of #{docs.size} hides a different value: #{docs}" do
          rows = rows_of(%w[id grp jb], *docs.each_with_index.map { |jb, i| [i + 1, 1, jb] })

          verdict = compare("SELECT jb FROM items ORDER BY grp, id", "SELECT jb FROM #{forward} ORDER BY grp", rows:)

          expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
        end
      end

      {
        "numeric" => ["np", "(1,1.0)", "(1,1.00)"],
        "interval" => ["ip", "(1,1 day)", "(1,24:00:00)"]
      }.each do |field, (column, first, second)|
        it "leaves out a composite with a #{field} field, whose equal values print differently" do
          rows = rows_of(["id", "grp", column], [1, 1, first], [2, 1, second])
          original = "SELECT #{column} FROM items ORDER BY grp, id"
          expect(raw(original, rows:).first.uniq.size).to eq(2)

          verdict = compare(original, "SELECT #{column} FROM #{forward} ORDER BY grp", rows:)

          expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
        end
      end

      it "refuses a jsonb column when only the candidate has a LIMIT" do
        rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'])

        verdict = compare("SELECT jb FROM items WHERE id = 1 ORDER BY grp",
                          "SELECT jb FROM #{forward} ORDER BY grp LIMIT 1", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "still compares a jsonb column when no tie holds different values" do
        rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'])
        original = "SELECT id, jb FROM #{forward} ORDER BY grp"

        expect(compare(original, "SELECT id, jb FROM #{reversed} ORDER BY grp", rows:).match?).to be(true)
        expect(fields(compare(original, "SELECT id, jb FROM items ORDER BY id DESC", rows:)))
          .to include(match: false, rule: :value)
      end

      describe "top-N over a jsonb column" do
        let(:docs) do
          rows_of(%w[id grp jb], [1, 1, '{"a": 1.0}'], [2, 1, '{"a": 1.00}'], [3, 2, '{"a": 3}'], [4, 3, '{"a": 4}'])
        end

        it "compares a top-N query whose sort key is unique, rerunning both without their LIMIT" do
          original = "SELECT id, jb FROM items ORDER BY id LIMIT 3"
          candidate = "SELECT id, jb FROM #{reversed} WHERE id > 0 ORDER BY id LIMIT 3"
          sent = nil
          verdict = runner.with_fixture(docs) do |tx|
            sent = SentQueries.new(tx)
            described_class.compare(sent, original:, candidate:)
          end

          expect(verdict.match?).to be(true)
          expect(sent.unlimited.size).to eq(2)
          expect(fields(compare(original, "SELECT id, jb FROM items ORDER BY id DESC LIMIT 3", rows: docs)))
            .to include(match: false, rule: :value)
        end

        it "refuses a tie that straddles the LIMIT and hides a different jsonb value" do
          original = "SELECT grp, jb FROM items ORDER BY grp LIMIT 1"

          expect(fields(compare(original, original, rows: docs))).to include(match: false, rule: :unsupported_order)
        end

        it "compares a LIMIT that a tie with a different jsonb value doesn't reach" do
          verdict = compare("SELECT grp, jb FROM items ORDER BY grp DESC LIMIT 2",
                            "SELECT grp, jb FROM #{reversed} ORDER BY grp DESC LIMIT 2", rows: docs)

          expect(verdict.match?).to be(true)
        end

        it "refuses a tie that straddles only the candidate's LIMIT" do
          verdict = compare("SELECT grp, jb FROM items WHERE id = 1 ORDER BY grp",
                            "SELECT grp, jb FROM items ORDER BY grp LIMIT 1", rows: docs)

          expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
        end

        it "still catches a candidate that drops a sort key" do
          rows = rows_of(%w[id grp jb], [1, 1, '{"a": 1}'], [2, 1, '{"a": 2}'], [3, 2, '{"a": 3}'])
          verdict = compare("SELECT id, grp, jb FROM items ORDER BY grp, id LIMIT 3",
                            "SELECT id, grp, jb FROM #{forward} ORDER BY grp LIMIT 3", rows:)

          expect(fields(verdict)).to include(match: false, mode: :ordered)
          expect(fields(verdict)[:rule]).not_to eq(:unsupported_order)
        end

        it "still refuses DISTINCT over a jsonb column" do
          sql = "SELECT DISTINCT id, jb FROM items ORDER BY id"

          expect(fields(compare(sql, sql, rows: docs))).to include(match: false, rule: :unsupported_order)
        end

        # Sorted by grp, the rows are 1, 1, 2, 3, and the two grp 1 rows
        # hide different jsonb values.
        it "places a constant OFFSET's window where the OFFSET starts" do
          reaches = "SELECT grp, jb FROM items ORDER BY grp OFFSET 1 LIMIT 1"
          misses = "SELECT grp, jb FROM items ORDER BY grp OFFSET 2 LIMIT 1"

          expect(fields(compare(reaches, reaches, rows: docs))).to include(match: false, rule: :unsupported_order)
          expect(compare(misses, misses, rows: docs).match?).to be(true)
        end

        it "refuses an OFFSET that isn't a constant, even where a constant one would compare" do
          sql = "SELECT grp, jb FROM items ORDER BY grp OFFSET (SELECT 2) LIMIT 1"

          expect(fields(compare(sql, sql, rows: docs))).to include(match: false, rule: :unsupported_order)
        end

        # Sorted by -grp, the rows are 3, 2, 1, 1.
        it "finds a hidden tie on an expression sort key only where it straddles the LIMIT" do
          misses = "SELECT grp, jb FROM items ORDER BY -grp LIMIT 2"
          reaches = "SELECT grp, jb FROM items ORDER BY -grp LIMIT 3"

          candidate = "SELECT grp, jb FROM #{reversed} ORDER BY -grp LIMIT 2"

          expect(compare(misses, candidate, rows: docs).match?).to be(true)
          expect(fields(compare(reaches, reaches, rows: docs))).to include(match: false, rule: :unsupported_order)
        end
      end

      it "refuses a numeric array in a tie, since {1.0} and {1.00} are equal" do
        rows = rows_of(%w[id grp na], [1, 1, "{1.0}"], [2, 1, "{1.00}"])

        verdict = compare("SELECT na FROM items ORDER BY grp, id", "SELECT na FROM #{forward} ORDER BY grp", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "refuses a numrange in a tie, since [1.0,2) and [1.00,2) are equal" do
        rows = rows_of(%w[id grp amount], [1, 1, "1.0"], [2, 1, "1.00"])
        original = "SELECT numrange(amount, 2) AS r FROM items ORDER BY grp, id"
        expect(raw(original, rows:).first.uniq.size).to eq(2)

        verdict = compare(original, "SELECT numrange(amount, 2) AS r FROM #{forward} ORDER BY grp", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "matches bpchar values that differ only in trailing spaces, whichever way the tie comes back" do
        rows = rows_of(%w[id grp c], [1, 1, "a"], [2, 1, "a  "])
        expect(raw("SELECT c FROM items ORDER BY id", rows:)).to eq([[["a"], ["a  "]]])
        original = "SELECT c FROM items ORDER BY grp, id LIMIT 1"

        verdicts = [forward, reversed].map do |from|
          compare(original, "SELECT c FROM #{from} ORDER BY grp LIMIT 1", rows:)
        end

        expect(verdicts.map(&:match?)).to eq([true, true])
      end
    end

    describe "a nondeterministic collation" do
      before do
        conn.exec(<<~SQL)
          CREATE COLLATION loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false)
        SQL
      end

      let(:words) { Quaack::Enclave::TableName.new(schema: "public", name: "words") }

      def word_rows(column)
        [[1, "a"], [2, "A"]].map do |id, value|
          Quaack::Enclave::ArenaRunner::FixtureRow.new(table: words, columns: ["id", "grp", column],
                                                       values: [id.to_s, "1", value])
        end
      end

      it "refuses when a column uses one" do
        conn.exec("CREATE TABLE words (id integer, grp integer, w text COLLATE loose)")
        rows = word_rows("w")
        candidate = "SELECT w FROM (SELECT * FROM words ORDER BY id OFFSET 0) s ORDER BY grp LIMIT 1"
        expect(raw(candidate, "SELECT w FROM words ORDER BY grp, id LIMIT 1", rows:).uniq.size).to eq(1)

        verdict = compare("SELECT w FROM words ORDER BY grp, id LIMIT 1", candidate, rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "refuses when the query names one" do
        conn.exec("CREATE TABLE words (id integer, grp integer, w text)")
        original = "SELECT w COLLATE loose AS w FROM words ORDER BY grp, id LIMIT 1"
        candidate = "SELECT w COLLATE loose AS w FROM words ORDER BY grp LIMIT 1"

        expect(fields(compare(original, candidate, rows: word_rows("w")))).to include(rule: :unsupported_order)
      end

      it "refuses when only the candidate names one" do
        conn.exec("CREATE TABLE words (id integer, grp integer, w text)")
        original = "SELECT w FROM words ORDER BY grp, id LIMIT 1"
        candidate = "SELECT w COLLATE loose AS w FROM words ORDER BY grp LIMIT 1"

        expect(fields(compare(original, candidate, rows: word_rows("w")))).to include(rule: :unsupported_order)
      end

      it "refuses when a domain uses one" do
        conn.exec("CREATE DOMAIN loose_text AS text COLLATE loose")
        conn.exec("CREATE TABLE words (id integer, grp integer, w text)")
        original = "SELECT w::loose_text AS w FROM words ORDER BY grp, id LIMIT 1"
        candidate = "SELECT w::loose_text AS w FROM words ORDER BY grp LIMIT 1"

        expect(fields(compare(original, candidate, rows: word_rows("w")))).to include(rule: :unsupported_order)
      end

      it "refuses when the query names one whose name needs quoting" do
        conn.exec(<<~SQL)
          CREATE COLLATION "it's loose" (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
          CREATE TABLE words (id integer, grp integer, w text)
        SQL
        original = %(SELECT w COLLATE "it's loose" AS w FROM words ORDER BY grp, id LIMIT 1)
        candidate = %(SELECT w COLLATE "it's loose" AS w FROM words ORDER BY grp LIMIT 1)

        expect(fields(compare(original, candidate, rows: word_rows("w")))).to include(rule: :unsupported_order)
      end

      it "refuses when a range type uses one" do
        conn.exec("CREATE TYPE loose_range AS RANGE (subtype = text, collation = loose)")
        conn.exec("CREATE TABLE words (id integer, grp integer, w text)")
        original = "SELECT loose_range(w, w, '[]') AS r FROM words ORDER BY grp, id LIMIT 1"
        candidate = "SELECT loose_range(w, w, '[]') AS r FROM words ORDER BY grp LIMIT 1"

        expect(fields(compare(original, candidate, rows: word_rows("w")))).to include(rule: :unsupported_order)
      end

      it "doesn't refuse when one only exists" do
        conn.exec("CREATE TABLE words (id integer, grp integer, w text)")
        sql = "SELECT id, w FROM words ORDER BY grp, id"

        expect(compare(sql, sql, rows: word_rows("w")).match?).to be(true)
      end
    end

    it "leaves columns btree can't order, such as json, out of the tiebreaker" do
      json = "SELECT doc, id FROM #{forward} ORDER BY grp"

      expect(compare(json, "SELECT doc, id FROM #{reversed} ORDER BY grp").match?).to be(true)
    end

    it "works with repeated output column names" do
      sql = "SELECT id, id, grp FROM #{forward} ORDER BY grp"

      expect(compare(sql, "SELECT id, id, grp FROM #{reversed} ORDER BY grp").match?).to be(true)
    end

    it "works on a set operation" do
      # grp 1 has six rows here, so LIMIT 6 cuts no tie.
      sql = "SELECT grp, label FROM items UNION ALL SELECT grp, label FROM items ORDER BY 1 LIMIT 6"

      candidate = "SELECT grp, label FROM #{reversed} UNION ALL SELECT grp, label FROM items ORDER BY 1 LIMIT 6"

      expect(compare(sql, candidate).match?).to be(true)
    end
  end

  describe "Tiebreaker::ORDERABLE_TYPES" do
    # Whether ORDER BY works on a column of the type, which is what the
    # tiebreaker needs. varchar and cidr sort through text and inet, so
    # they have no btree operator class of their own.
    def orderable?(oid)
      name = conn.exec_params("SELECT format_type($1, NULL)", [oid]).getvalue(0, 0)
      conn.exec("SELECT NULL::#{name} ORDER BY 1")
      true
    rescue PG::UndefinedFunction
      false
    end

    it "names each type by its name and array in the catalog" do
      listed = described_class::Tiebreaker::ORDERABLE_TYPES.map { |name, (oid, array)| [name.to_s, oid.to_s, array.to_s] }
      catalog = listed.map do |_, oid, _|
        conn.exec_params("SELECT typname, oid, typarray FROM pg_type WHERE oid = $1", [oid]).values.first
      end

      expect(catalog).to eq(listed)
    end

    it "lists only types, and arrays of them, that ORDER BY can sort" do
      expect(described_class::Tiebreaker::ORDERABLE_OIDS.reject { |oid| orderable?(oid) }).to eq([])
    end

    it "the check catches a type ORDER BY can't sort" do
      # json, xml, point, and json[]
      expect([114, 142, 600, 199].map { |oid| orderable?(oid) }).to eq([false, false, false, false])
    end
  end

  describe "FETCH FIRST ... WITH TIES" do
    let(:original) { "SELECT id, grp FROM #{forward} ORDER BY grp FETCH FIRST 1 ROWS WITH TIES" }

    # The comparison can't check the order of WITH TIES rows, so it fails
    # closed and never says match, even for the same query.
    it "is an unsupported_order mismatch, whatever the candidate, and runs nothing" do
      reordered = "SELECT * FROM (SELECT id, grp FROM items ORDER BY grp FETCH FIRST 3 ROWS WITH TIES) s " \
                  "ORDER BY id DESC"
      verdicts = [original, reordered, "SELECT broken FROM nowhere ORDER BY 1"].map { |c| compare(original, c) }

      expect(verdicts.map { |v| v.to_h.slice(:match, :mode, :rule, :expected_rows, :actual_rows) }.uniq)
        .to eq([{ match: false, mode: :with_ties, rule: :unsupported_order, expected_rows: nil, actual_rows: nil }])
    end
  end

  describe "LIMIT with no ORDER BY" do
    let(:original) { "SELECT id, grp FROM #{forward} LIMIT 2" }

    it "matches a different subset of the full result" do
      candidate = "SELECT id, grp FROM #{reversed} LIMIT 2"
      first, second = raw(original, candidate)
      expect(first.sort).not_to eq(second.sort)

      expect(fields(compare(original, candidate))).to include(match: true, mode: :subset)
    end

    it "is a subset mismatch for a row that isn't in the full result" do
      verdict = compare(original, "SELECT id + 100, grp FROM items LIMIT 2")

      expect(fields(verdict)).to include(match: false, mode: :subset, rule: :subset, row: 0)
    end

    it "is a row_count mismatch for the wrong number of rows" do
      verdict = compare(original, "SELECT id, grp FROM items LIMIT 3")

      expect(verdict.to_h).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 3)
    end

    it "expects fewer rows when the limit is more than the table has" do
      verdict = compare("SELECT id FROM items LIMIT 10", "SELECT id FROM #{reversed}")

      expect(verdict.to_h).to include(match: true, expected_rows: 5, actual_rows: 5)
    end

    # or_to_union keeps the LIMIT outside its UNION, so the rewrite can
    # keep other rows than the original does. That's a valid answer, so
    # compare_in_load_orders calls it a match (task 20261002-5). This
    # checks that call only, not rewrite-test or counterexamples, which
    # call it too.
    it "matches an or_to_union rewrite that keeps other rows under the LIMIT" do
      original = "SELECT items.id, items.grp FROM public.items WHERE items.id IN (SELECT 5) OR items.grp = 1 LIMIT 2"
      rewrite = Quaack::Enclave::RewriteRules::OrToUnion.new
                                                        .rewrites(PgQuery.parse(original),
                                                                  Quaack::Enclave::RewriteRules::Catalog.new(conn))
      candidate = Quaack::Enclave::Deparse.faithfully(rewrite.first.tree)
      # Loaded backwards, so the original's scan reaches row 5 first.
      backwards = fixture.reverse
      first, second = raw(original, candidate, rows: backwards)
      expect(first.sort).not_to eq(second.sort)

      verdict = described_class.compare_in_load_orders(runner, backwards, original:, candidate:)
      expect(fields(verdict)).to include(match: true, mode: :subset)
    end

    it "treats OFFSET the same way" do
      verdict = compare("SELECT id FROM #{forward} OFFSET 3", "SELECT id FROM #{reversed} OFFSET 3")
      short = compare("SELECT id FROM #{forward} OFFSET 3", "SELECT id FROM #{reversed} OFFSET 4")

      expect(verdict.to_h).to include(match: true, mode: :subset, expected_rows: 2)
      expect(short.to_h).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 1)
    end
  end

  # pg_query's deparser writes (a OR b) IS NULL as a OR b IS NULL, which
  # Postgres reads as a OR (b IS NULL). Only rows 4 and 5, whose price is
  # NULL, meet the first, and only rows 2 and 3 meet the second.
  describe "a query the deparser would change without the round-trip guard" do
    let(:grouped) { "(price > 0.15 OR label = 'zz') IS NULL" }

    it "rows differ between the query and its raw deparse" do
      written = "SELECT id FROM items WHERE #{grouped}"
      deparsed = PgQuery.deparse(PgQuery.parse(written).tree)

      expect(raw(written, deparsed).map { |rows| rows.flatten.sort }).to eq([%w[4 5], %w[2 3]])
    end

    it "compares a LIMIT with no ORDER BY against the query's own full result" do
      original = "SELECT id FROM items WHERE #{grouped} LIMIT 1"

      expect(fields(compare(original, "SELECT id FROM items WHERE price IS NULL LIMIT 1")))
        .to include(match: true, mode: :subset)
      expect(fields(compare(original, "SELECT id FROM items WHERE id = 2 LIMIT 1")))
        .to include(match: false, mode: :subset, rule: :subset)
    end

    it "compares an ORDER BY against the query's own rows" do
      original = "SELECT id FROM items WHERE #{grouped} ORDER BY grp"

      expect(fields(compare(original, "SELECT id FROM items WHERE price IS NULL ORDER BY grp")))
        .to include(match: true, mode: :ordered)
      expect(fields(compare(original, "SELECT id FROM items WHERE id IN (2, 3) ORDER BY grp")))
        .to include(match: false, mode: :ordered)
    end
  end

  describe "values" do
    it "matches float sums that differ only by rounding noise" do
      original = "SELECT sum(price) FROM #{forward}"
      candidate = "SELECT sum(price) FROM #{reversed}"
      first, second = raw(original, candidate)
      expect(first).not_to eq(second)

      expect(compare(original, candidate).match?).to be(true)
    end

    it "doesn't match a float that's off by more than the tolerance" do
      verdict = compare("SELECT sum(price) FROM items", "SELECT sum(price) * 1.000001 FROM items")

      expect(fields(verdict)).to include(match: false, rule: :multiset)
    end

    it "matches numerics by value, whatever scale Postgres prints" do
      candidate = "SELECT amount::numeric(10, 4) FROM items"
      expect(raw("SELECT amount FROM items", candidate).uniq.size).to eq(2)

      expect(compare("SELECT amount FROM items", candidate).match?).to be(true)
    end
  end

  describe "trust boundary" do
    let(:planted) do
      [Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns: %w[id grp price amount label],
                                                    values: ["9", "1", "9.5", "9", sentinel])]
    end

    it "keeps row values out of every verdict" do
      rows = fixture + planted
      verdicts = [
        compare("SELECT label, price FROM items", "SELECT label, price + 1 FROM items", rows:),
        compare("SELECT label FROM items ORDER BY label", "SELECT label FROM items ORDER BY label DESC", rows:),
        compare("SELECT label FROM items LIMIT 6", "SELECT label || 'x' FROM items LIMIT 6", rows:),
        compare("SELECT label FROM items ORDER BY label", "SELECT label FROM items", rows:)
      ]

      expect(verdicts.map(&:rule)).to eq(%i[multiset value subset candidate_unordered])
      verdicts.each do |verdict|
        expect(verdict.inspect).not_to include(sentinel)
        expect(verdict.to_h.to_s).not_to include(sentinel)
      end
    end

    it "keeps the SQL out of a parse error" do
      expect { compare("SELECT '#{sentinel}' FROM", "SELECT 1") }
        .to raise_error(described_class::Error) { |e| expect(e.message).not_to include(sentinel) }
    end

    it "the check catches a sentinel when one is planted" do
      expect(raw("SELECT label FROM items", rows: planted).inspect).to include(sentinel)
    end
  end
end
