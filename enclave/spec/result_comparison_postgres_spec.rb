# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# fixture-compare against a real arena: load a fixture with ArenaRunner, run the
# original and a candidate, and compare them under each ordering rule.
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
        c bpchar,
        na numeric[],
        np npair,
        ip ipair
      )
    SQL
  end

  def rows_of(columns, *rows)
    rows.map do |values|
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: items, columns:, values: values.map(&:to_s))
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

    it "refuses a LIMIT that splits a tie, even for a good candidate" do
      limited = "#{original} LIMIT 2"
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 2"
      first, second = raw(limited, candidate)
      expect(first.sort).not_to eq(second.sort)

      expect(fields(compare(limited, candidate))).to include(match: false, rule: :unsupported_order)
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

    # The original's rows depend on how a tie at a LIMIT or OFFSET cut, or
    # a DISTINCT ON pick, breaks. The two tiebreaker runs only expose the
    # first and last rows of each tie, so the comparison refuses.
    describe "a tie at a cut" do
      # Reads items with id 3, or 2 below, first, then by id.
      def moved(id) = "(SELECT * FROM items ORDER BY id = #{id} DESC, id OFFSET 0) s"

      def expect_refused(original, candidate, rows)
        expect(fields(compare(original, candidate, rows:)))
          .to eq(match: false, mode: :ordered, rule: :unsupported_order, row: nil, column: nil)
      end

      let(:four) { rows_of(%w[id grp], [1, 0], [2, 1], [3, 2], [4, 1]) }

      it "refuses a LIMIT that cuts a tie" do
        original = "SELECT id, grp FROM items ORDER BY grp LIMIT 2"
        candidate = "SELECT id, grp FROM #{moved(3)} ORDER BY LEAST(grp, 1) LIMIT 2"
        expect(raw(candidate, rows: four)).to eq([[%w[1 0], %w[3 2]]])

        expect_refused(original, candidate, four)
      end

      it "refuses before the candidate runs" do
        failing = "SELECT id, grp / (id - id) AS grp FROM items ORDER BY grp LIMIT 2"
        expect { raw(failing, rows: four) }.to raise_error(Quaack::Enclave::ArenaRunner::Error)

        expect_refused("SELECT id, grp FROM items ORDER BY grp LIMIT 2", failing, four)
      end

      it "refuses a DISTINCT ON whose pick is a tie" do
        rows = rows_of(%w[id grp price], [1, 1, 1], [2, 1, 2], [3, 1, 1])

        expect_refused("SELECT DISTINCT ON (grp) grp, id FROM items ORDER BY grp, price",
                       "SELECT DISTINCT ON (grp) grp, id FROM #{moved(2)} ORDER BY grp, LEAST(price, 1)", rows)
      end

      it "refuses an OFFSET that cuts a tie" do
        rows = rows_of(%w[id grp], [1, 0], [2, 1], [3, 2], [4, 1], [5, 3])

        candidate = "SELECT id, grp FROM #{moved(3)} ORDER BY CASE WHEN grp = 2 THEN 1 ELSE grp END OFFSET 1 LIMIT 1"

        expect_refused("SELECT id, grp FROM items ORDER BY grp OFFSET 1 LIMIT 1", candidate, rows)
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

    # btree calls these values equal, but they print differently, so a
    # tiebreaker can't split them and the comparator would see them differ.
    describe "types whose equal values print differently" do
      it "refuses an interval column in a tie, since the tie can come back either way" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"])
        original = "SELECT iv FROM items ORDER BY grp, id"
        candidate = "SELECT iv FROM #{forward} ORDER BY grp"
        forward_rows, reversed_rows = raw(candidate, "SELECT iv FROM #{reversed} ORDER BY grp", rows:)
        expect([forward_rows == raw(original, rows:).first, forward_rows == reversed_rows]).to eq([true, false])

        expect(fields(compare(original, candidate, rows:))).to include(match: false, rule: :unsupported_order)
      end

      it "refuses an interval column under a LIMIT" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"])

        verdict = compare("SELECT iv FROM items ORDER BY grp, id LIMIT 1",
                          "SELECT iv FROM #{forward} ORDER BY grp LIMIT 1", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "refuses an interval column when only the original has a LIMIT" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"])

        verdict = compare("SELECT iv FROM items ORDER BY grp LIMIT 1",
                          "SELECT iv FROM items WHERE id = 1 ORDER BY grp", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      # The odd interval sits after a repeat, and then between repeats, so
      # checking only the first two rows, or only the first and last, of a
      # tie misses it in one fixture or the other.
      [
        ["1 day", "1 day", "24 hours"],
        ["1 day", "1 day", "24 hours", "1 day"]
      ].each do |intervals|
        it "refuses an interval column when a tie of #{intervals.size} hides a different interval: #{intervals}" do
          rows = rows_of(%w[id grp iv], *intervals.each_with_index.map { |iv, i| [i + 1, 1, iv] })

          verdict = compare("SELECT iv FROM items ORDER BY grp, id", "SELECT iv FROM #{forward} ORDER BY grp", rows:)

          expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
        end
      end

      {
        "numeric" => ["np", "(1,1.0)", "(1,1.00)"],
        "interval" => ["ip", "(1,1 day)", "(1,24 hours)"]
      }.each do |field, (column, first, second)|
        it "leaves out a composite with a #{field} field, whose equal values print differently" do
          rows = rows_of(["id", "grp", column], [1, 1, first], [2, 1, second])
          original = "SELECT #{column} FROM items ORDER BY grp, id"
          expect(raw(original, rows:).first.uniq.size).to eq(2)

          verdict = compare(original, "SELECT #{column} FROM #{forward} ORDER BY grp", rows:)

          expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
        end
      end

      it "refuses an interval column when only the candidate has a LIMIT" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"])

        verdict = compare("SELECT iv FROM items WHERE id = 1 ORDER BY grp",
                          "SELECT iv FROM #{forward} ORDER BY grp LIMIT 1", rows:)

        expect(fields(verdict)).to include(match: false, rule: :unsupported_order)
      end

      it "still compares an interval column when no tie holds different intervals" do
        rows = rows_of(%w[id grp iv], [1, 1, "1 day"], [2, 1, "24 hours"])
        original = "SELECT id, iv FROM #{forward} ORDER BY grp"

        expect(compare(original, "SELECT id, iv FROM #{reversed} ORDER BY grp", rows:).match?).to be(true)
        expect(fields(compare(original, "SELECT id, iv FROM items ORDER BY id DESC", rows:)))
          .to include(match: false, rule: :value)
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
