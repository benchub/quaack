# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# Step 9d against a real arena: load a fixture with ArenaRunner, run the
# original and a candidate, and compare them under each ordering rule.
RSpec.describe Quaack::Enclave::ResultComparison do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }
  let(:sentinel) { "SENTINEL-2b8e61" }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE items (
        id integer PRIMARY KEY,
        grp integer NOT NULL,
        price float8,
        amount numeric,
        label text,
        doc json
      )
    SQL
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

    it "keeps the LIMIT, so a limit that splits a tie still matches" do
      limited = "#{original} LIMIT 2"
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 2"
      first, second = raw(limited, candidate)
      expect(first.sort).not_to eq(second.sort)

      expect(fields(compare(limited, candidate))).to include(match: true, mode: :ordered)
    end

    it "keeps the OFFSET" do
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp LIMIT 2 OFFSET 1"

      expect(compare("#{original} LIMIT 2 OFFSET 1", candidate).match?).to be(true)
      expect(fields(compare("#{original} LIMIT 2 OFFSET 2", candidate))).to include(match: false, rule: :value)
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

    it "leaves columns btree can't order, such as json, out of the tiebreaker" do
      json = "SELECT doc, id FROM #{forward} ORDER BY grp"

      expect(compare(json, "SELECT doc, id FROM #{reversed} ORDER BY grp").match?).to be(true)
    end

    it "works with repeated output column names" do
      sql = "SELECT id, id, grp FROM #{forward} ORDER BY grp"

      expect(compare(sql, "SELECT id, id, grp FROM #{reversed} ORDER BY grp").match?).to be(true)
    end

    it "works on a set operation" do
      sql = "SELECT grp, label FROM items UNION ALL SELECT grp, label FROM items ORDER BY 1 LIMIT 3"

      candidate = "SELECT grp, label FROM #{reversed} UNION ALL SELECT grp, label FROM items ORDER BY 1 LIMIT 3"

      expect(compare(sql, candidate).match?).to be(true)
    end
  end

  describe "ORDERABLE_TYPES" do
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
      listed = described_class::ORDERABLE_TYPES.map { |name, (oid, array)| [name.to_s, oid.to_s, array.to_s] }
      catalog = listed.map do |_, oid, _|
        conn.exec_params("SELECT typname, oid, typarray FROM pg_type WHERE oid = $1", [oid]).values.first
      end

      expect(catalog).to eq(listed)
    end

    it "lists only types, and arrays of them, that ORDER BY can sort" do
      expect(described_class::ORDERABLE_OIDS.reject { |oid| orderable?(oid) }).to eq([])
    end

    it "the check catches a type ORDER BY can't sort" do
      # json, xml, point, and json[]
      expect([114, 142, 600, 199].map { |oid| orderable?(oid) }).to eq([false, false, false, false])
    end
  end

  describe "FETCH FIRST ... WITH TIES" do
    let(:original) { "SELECT id, grp FROM #{forward} ORDER BY grp FETCH FIRST 1 ROWS WITH TIES" }

    it "compares the tied rows as a multiset" do
      candidate = "SELECT id, grp FROM #{reversed} ORDER BY grp FETCH FIRST 1 ROWS WITH TIES"
      expect(raw(original, candidate).uniq.size).to eq(2)

      expect(fields(compare(original, candidate))).to include(match: true, mode: :with_ties)
    end

    it "is a row_count mismatch for a plain LIMIT" do
      verdict = compare(original, "SELECT id, grp FROM items ORDER BY grp LIMIT 1")

      expect(fields(verdict)).to include(match: false, mode: :with_ties, rule: :row_count)
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
