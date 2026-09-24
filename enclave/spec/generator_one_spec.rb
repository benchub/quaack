# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/generator_one"

RSpec.describe Quaack::Enclave::GeneratorOne do
  let(:orders) { table_name("orders") }
  let(:customers) { table_name("customers") }

  def table_name(name, schema: "public") = Quaack::Enclave::TableName.new(schema:, name:)

  def column(n_distinct, null_frac: 0.0, correlation: nil)
    Quaack::Enclave::ColumnStatistics.new(n_distinct:, null_frac:, correlation:)
  end

  # column_names defaults to the columns that have statistics, plus any
  # extra names given.
  def table(name, columns = {}, extra: [], reltuples: 1000.0)
    Quaack::Enclave::TableStatistics.new(name:, reltuples:, columns:, column_names: columns.keys + extra, indexes: {})
  end

  def statistics(*tables) = Quaack::Enclave::Statistics.new(tables:)

  def generate(sql, stats, **limits) = described_class.candidates(PgQuery.parse(sql), stats, **limits)

  def desc(name, nulls: :first) = Quaack::Enclave::IndexCandidate::KeyColumn.new(name:, direction: :desc, nulls:)

  def asc(name, nulls: :last) = Quaack::Enclave::IndexCandidate::KeyColumn.new(name:, direction: :asc, nulls:)

  def btree(table, key, include = [])
    Quaack::Enclave::IndexCandidate.new(table:, key:, include:, sources: [:parse])
  end

  def brin(table, column)
    Quaack::Enclave::IndexCandidate.new(table:, key: [column], access_method: :brin, sources: [:parse])
  end

  # Candidates compare without sources, so check those on their own.
  def keys(candidates) = candidates.map { |c| [c.table.name, c.key.map(&:name), c.include] }

  describe "equality columns" do
    let(:stats) do
      statistics(table(orders, { "status" => column(6), "customer_id" => column(900), "region" => column(40) },
                       extra: %w[id total]))
    end

    it "ranks them most selective first and emits every leading prefix" do
      result = generate("SELECT id FROM public.orders WHERE status = 1 AND customer_id = 2 AND region = 3", stats)

      expect(result).to eq([
                             btree(orders, %w[customer_id], %w[id]),
                             btree(orders, %w[customer_id region], %w[id]),
                             btree(orders, %w[customer_id region status], %w[id])
                           ])
    end

    it "tags every candidate as from the parse, with no predicate and not unique" do
      result = generate("SELECT id FROM public.orders WHERE status = 1 AND customer_id = 2", stats)

      expect(result.size).to eq(2)
      expect(result.map(&:sources)).to all(eq(Set[:parse]))
      expect(result.map(&:predicate)).to all(be_nil)
      expect(result.map(&:unique)).to all(be(false))
      expect(result.map(&:access_method)).to all(eq(:btree))
    end

    it "converts a negative n_distinct to a fraction of reltuples before ranking" do
      # -0.5 of 1,000,000 rows is 500,000 distinct values, far more selective
      # than 1,000.
      stats = statistics(table(orders, { "a" => column(1000), "b" => column(-0.5) }, reltuples: 1_000_000))

      expect(keys(generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2", stats)).last)
        .to eq(["orders", %w[b a], []])
    end

    it "discounts by null_frac" do
      # The same distinct count, but b is 90% null, so b = const matches fewer rows.
      stats = statistics(table(orders, { "a" => column(100), "b" => column(100, null_frac: 0.9) }))

      expect(keys(generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2", stats)).last)
        .to eq(["orders", %w[b a], []])
    end

    it "ranks a column tested only with IS NULL by null_frac, the fraction of rows it matches" do
      # n = const would match 0.1 / 1000 of the rows, but n IS NULL matches 0.9.
      stats = statistics(table(orders, { "a" => column(10), "n" => column(1000, null_frac: 0.9) }))

      expect(keys(generate("SELECT 1 FROM public.orders WHERE n IS NULL AND a = 1", stats)).last)
        .to eq(["orders", %w[a n], []])
    end

    it "ranks by null_frac even when the IS NULL is repeated" do
      stats = statistics(table(orders, { "a" => column(10), "n" => column(1000, null_frac: 0.9) }))

      expect(keys(generate("SELECT 1 FROM public.orders WHERE n IS NULL AND n IS NULL AND a = 1", stats)).last)
        .to eq(["orders", %w[a n], []])
    end

    # The 50-column tests under "which predicates count" prove the query-order
    # tie-break. Three columns are too few: Ruby's sort keeps them in order
    # anyway.
    it "puts columns with unknown selectivity last" do
      stats = statistics(table(orders, { "a" => column(10), "z" => column(0) }, extra: %w[m]))
      key = generate("SELECT 1 FROM public.orders WHERE z = 1 AND m = 2 AND a = 3", stats).last.key.map(&:name)

      expect(key.first).to eq("a")
      expect(key.drop(1)).to contain_exactly("z", "m")
    end
  end

  describe "input" do
    let(:stats) { statistics(table(orders, { "status" => column(6) }), table(customers, { "id" => column(-1) })) }

    it "refuses anything but a pg_query parse result" do
      expect { described_class.candidates("SELECT 1", stats) }.to raise_error(ArgumentError, /pg_query parse result/)
    end

    # The statement checks generator one had until 20260923-33 are
    # SupportedSql's now.
    it "refuses more or fewer than one statement" do
      expect { generate("SELECT 1; SELECT 2", stats) }
        .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: ParseResult with 2 statements, not one")
      expect { generate("", stats) }.to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: ParseResult with 0 statements, not one")
    end

    it "refuses a statement that isn't a SELECT" do
      expect { generate("DELETE FROM public.orders WHERE status = 1", stats) }
        .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: DeleteStmt")
    end

    # Each would give candidates without the check.
    {
      "SIMILAR TO" => ["SELECT 1 FROM public.orders WHERE status SIMILAR TO 'a'", "A_Expr AEXPR_SIMILAR"],
      "TABLESAMPLE" => ["SELECT 1 FROM public.orders TABLESAMPLE system (1), public.customers c WHERE c.id = 1",
                        "RangeTableSample"],
      "ROW" => ["SELECT 1 FROM public.orders WHERE status = 1 AND ROW(status) IS NOT NULL", "RowExpr"]
    }.each do |construct, (sql, detail)|
      it "refuses #{construct}, which isn't on the supported list" do
        expect { generate(sql, stats) }.to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: #{detail}")
      end
    end

    it "refuses a set operation" do
      expect { generate("SELECT 1 FROM public.orders UNION SELECT 2 FROM public.customers", stats) }
        .to raise_error(ArgumentError, /set operation/)
    end

    it "refuses an unqualified relation, naming it" do
      expect { generate("SELECT 1 FROM orders WHERE status = 1", stats) }
        .to raise_error(ArgumentError, /relation orders isn't schema qualified/)
    end

    it "refuses an unqualified relation inside a subquery or a CTE" do
      expect { generate("SELECT 1 FROM public.orders WHERE status IN (SELECT id FROM customers)", stats) }
        .to raise_error(ArgumentError, /relation customers isn't schema qualified/)
      expect { generate("WITH c AS (SELECT id FROM customers) SELECT 1 FROM public.orders", stats) }
        .to raise_error(ArgumentError, /relation customers isn't schema qualified/)
    end

    it "accepts an unqualified reference to a CTE" do
      sql = "WITH c AS (SELECT id FROM public.customers) SELECT 1 FROM public.orders, c WHERE status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], []]])
    end

    it "raises KeyError when a table in the query has no statistics" do
      expect { generate("SELECT 1 FROM public.missing", stats) }.to raise_error(KeyError, /public.missing/)
    end

    it "takes a key cap of one" do
      expect(keys(generate("SELECT 1 FROM public.orders WHERE status = 1", stats, max_key_columns: 1)))
        .to eq([["orders", %w[status], []]])
    end

    it "keeps its helpers private" do
      expect(described_class.constants).to eq([])
    end

    it "refuses a data-modifying CTE, even inside a subquery" do
      expect { generate("WITH d AS (DELETE FROM public.orders RETURNING *) SELECT 1 FROM d", stats) }
        .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: DeleteStmt")
      sql = "SELECT 1 FROM public.orders WHERE status IN " \
            "(WITH u AS (UPDATE public.customers SET id = 1 RETURNING id) SELECT id FROM u)"
      expect { generate(sql, stats) }.to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: UpdateStmt")
    end

    it "refuses SELECT ... INTO" do
      expect { generate("SELECT status INTO public.copy FROM public.orders", stats) }
        .to raise_error(Quaack::Enclave::SupportedSql::Error, "unsupported_construct: IntoClause")
    end

    it "refuses an unqualified table that a CTE's name doesn't reach" do
      # A plain CTE's own body can't see its name, so orders there is a real table.
      expect { generate("WITH orders AS (SELECT 1 FROM orders) SELECT 1 FROM public.orders", stats) }
        .to raise_error(ArgumentError, /relation orders isn't schema qualified/)
      # A CTE in one subquery doesn't reach another.
      sql = "SELECT 1 FROM public.orders WHERE EXISTS (WITH customers AS (SELECT 1) SELECT 1 FROM customers) " \
            "AND EXISTS (SELECT 1 FROM customers)"
      expect { generate(sql, stats) }.to raise_error(ArgumentError, /relation customers isn't schema qualified/)
      # A later CTE doesn't reach an earlier one.
      expect { generate("WITH a AS (SELECT 1 FROM b), b AS (SELECT 1) SELECT 1 FROM public.orders", stats) }
        .to raise_error(ArgumentError, /relation b isn't schema qualified/)
    end

    it "accepts references a CTE's name does reach" do
      ["WITH RECURSIVE t AS (SELECT 1 AS n UNION ALL SELECT n FROM t) SELECT 1 FROM public.orders, t WHERE status = 1",
       "WITH a AS (SELECT 1), b AS (SELECT 1 FROM a) SELECT 1 FROM public.orders, b WHERE status = 1",
       "WITH a AS (SELECT 1) SELECT 1 FROM public.orders WHERE status = 1 AND EXISTS (SELECT 1 FROM a)",
       "WITH a AS (SELECT 1) SELECT 1 FROM public.orders WHERE status = 1 " \
       "AND EXISTS (WITH b AS (SELECT 1 FROM a) SELECT 1 FROM b)",
       "WITH RECURSIVE a AS (SELECT 1 FROM b), b AS (SELECT 1) SELECT 1 FROM public.orders, a WHERE status = 1"]
        .each do |sql|
        expect(keys(generate(sql, stats))).to eq([["orders", %w[status], []]]), sql
      end
    end

    it "refuses BRIN limits that aren't finite numbers in range" do
      [{ brin_min_correlation: "0.9" }, { brin_min_correlation: 1.5 }, { brin_min_correlation: -0.1 },
       { brin_min_correlation: Float::NAN }, { brin_min_reltuples: nil },
       { brin_min_reltuples: Float::INFINITY }, { brin_min_reltuples: Complex(1, 1) }].each do |limits|
        expect { generate("SELECT 1 FROM public.orders", stats, **limits) }
          .to raise_error(ArgumentError, /#{limits.keys.first}/), limits.inspect
      end
    end

    it "accepts BRIN limits at the edges of their ranges" do
      expect(generate("SELECT 1 FROM public.orders WHERE status = 1", stats, brin_min_correlation: 0,
                                                                             brin_min_reltuples: 0).size).to eq(1)
      expect(generate("SELECT 1 FROM public.orders WHERE status = 1", stats, brin_min_correlation: 1).size).to eq(1)
      # Any finite row threshold works, even a negative one.
      expect(generate("SELECT 1 FROM public.orders WHERE status = 1", stats, brin_min_reltuples: -1).size).to eq(1)
    end

    it "refuses a key cap below one" do
      expect { generate("SELECT 1 FROM public.orders", stats, max_key_columns: 0) }
        .to raise_error(ArgumentError, /max_key_columns/)
    end

    it "refuses a key cap that isn't an Integer" do
      expect { generate("SELECT 1 FROM public.orders", stats, max_key_columns: 2.0) }
        .to raise_error(ArgumentError, /max_key_columns/)
    end
  end

  describe "mapping columns to tables" do
    let(:stats) do
      statistics(
        table(orders, { "status" => column(6), "customer_id" => column(900), "region" => column(40) },
              extra: %w[id total parent_id]),
        table(customers, { "id" => column(-1), "region" => column(40), "name" => column(-0.9) })
      )
    end

    it "resolves an alias" do
      expect(keys(generate("SELECT o.id FROM public.orders o WHERE o.status = 1", stats)))
        .to eq([["orders", %w[status], %w[id]]])
    end

    it "resolves a column qualified by the table name or by schema and table name" do
      sql = "SELECT orders.id FROM public.orders WHERE orders.status = 1 AND public.orders.region = 2"

      expect(keys(generate(sql, stats)).last).to eq(["orders", %w[region status], %w[id]])
    end

    it "doesn't resolve the table name once the table has an alias" do
      expect(generate("SELECT 1 FROM public.orders o WHERE orders.status = 1", stats)).to eq([])
    end

    it "counts a join condition as an equality column on each side, in FROM order" do
      sql = "SELECT o.id, c.name FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "WHERE o.status = 1"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["orders", %w[customer_id], %w[id]],
                                                 ["orders", %w[customer_id status], %w[id]],
                                                 ["orders", %w[status], %w[id]],
                                                 ["customers", %w[id], %w[name]]
                                               ])
    end

    it "counts a join condition written in WHERE" do
      sql = "SELECT 1 FROM public.orders o, public.customers c WHERE o.customer_id = c.id"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["customers", %w[id], []]])
    end

    it "reads the ON clauses of nested joins" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "JOIN public.orders p ON p.id = o.parent_id AND p.status = 2"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["orders", %w[customer_id], []],
                                                 ["orders", %w[customer_id parent_id], []],
                                                 ["customers", %w[id], []],
                                                 ["orders", %w[status], []],
                                                 ["orders", %w[status id], []]
                                               ])
    end

    it "reads JOIN ... USING as a join condition on both sides" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c USING (region)"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[region], []], ["customers", %w[region], []]])
    end

    it "reads USING after a nested join, skipping a side where more than one table has the column" do
      # The left side is (o JOIN c), where only c has name. For region, both
      # o and c have it, so that side is skipped.
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "JOIN public.customers d USING (name) JOIN public.customers e USING (region)"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["customers", %w[id], []],
                                                ["customers", %w[id name], []], ["customers", %w[name], []],
                                                ["customers", %w[region], []]])
    end

    it "also builds each table's keys with its join columns left out, after the join-led keys" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "WHERE o.status = 1 AND o.region = 2"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["orders", %w[customer_id], []],
                                                 ["orders", %w[customer_id region], []],
                                                 ["orders", %w[customer_id region status], []],
                                                 ["orders", %w[region], []],
                                                 ["orders", %w[region status], []],
                                                 ["customers", %w[id], []]
                                               ])
    end

    it "leaves JOIN ... USING columns out of the second set too" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c USING (region) WHERE o.status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[region], []], ["orders", %w[region status], []],
                                                ["orders", %w[status], []], ["customers", %w[region], []]])
    end

    it "leaves out a column that two join conditions name" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "JOIN public.customers d ON d.id = o.customer_id WHERE o.status = 1"

      expect(keys(generate(sql, stats)).select { |table, _, _| table == "orders" })
        .to eq([["orders", %w[customer_id], []], ["orders", %w[customer_id status], []], ["orders", %w[status], []]])
    end

    it "keeps a join column in the second set when a filter also names it" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "WHERE o.customer_id = 5 AND o.status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["orders", %w[customer_id status], []],
                                                ["customers", %w[id], []]])
    end

    it "keeps a join column in the second set when a filter also names it, whichever comes first" do
      sql = "SELECT 1 FROM public.orders o, public.customers c " \
            "WHERE o.customer_id = c.id AND o.customer_id = 5 AND o.status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["orders", %w[customer_id status], []],
                                                ["customers", %w[id], []]])
    end

    it "skips an IS NULL in a higher ON on a table a lower LEFT JOIN made nullable" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
            "JOIN public.customers i ON i.id = c.id AND o.region IS NULL"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []]])
    end

    it "skips an IS NULL in a higher ON when the lower LEFT JOIN is on its right" do
      sql = "SELECT 1 FROM public.customers c JOIN " \
            "(public.customers i LEFT JOIN public.orders o ON o.customer_id = i.id) ON i.id = c.id AND o.region IS NULL"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []]])
    end

    it "skips a WHERE IS NULL on either side of a FULL JOIN" do
      sql = "SELECT 1 FROM public.orders o FULL JOIN public.customers c ON o.customer_id = c.id " \
            "WHERE o.region IS NULL AND c.name IS NULL"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["customers", %w[id], []]])
    end

    it "skips an IS NULL in a RIGHT JOIN's ON on a table a lower LEFT JOIN made nullable" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
            "RIGHT JOIN public.customers i ON o.region IS NULL AND i.id = c.id"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []]])
    end

    it "keeps an IS NULL in an outer join's own ON, which filters the nullable side's scan" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id AND o.region IS NULL"

      expect(keys(generate(sql, stats))).to include(["orders", %w[region], []])
    end

    it "counts a strict WHERE filter on the nullable side, since Postgres then makes the join inner" do
      sql = "SELECT c.name FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
            "WHERE o.status = 1 AND o.region = 7"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["customers", %w[id], %w[name]],
                                                 ["orders", %w[customer_id], []],
                                                 ["orders", %w[customer_id region], []],
                                                 ["orders", %w[customer_id region status], []],
                                                 ["orders", %w[region], []],
                                                 ["orders", %w[region status], []]
                                               ])
    end

    it "skips a WHERE conjunct on the nullable side of a LEFT JOIN, like an anti-join's IS NULL" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
            "WHERE o.status IS NULL"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []]])
    end

    it "skips an ON conjunct of a LEFT JOIN that touches only the preserved side, and keeps the rest" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o " \
            "ON o.customer_id = c.id AND c.region = 5 AND o.status = 1"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []],
                                                ["orders", %w[customer_id status], []], ["orders", %w[status], []]])
    end

    it "treats a RIGHT JOIN the same way, with the sides swapped" do
      sql = "SELECT 1 FROM public.orders o RIGHT JOIN public.customers c " \
            "ON o.customer_id = c.id AND c.region = 5 AND o.status = 1 WHERE o.region IS NULL"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["orders", %w[customer_id status], []],
                                                ["orders", %w[status], []], ["customers", %w[id], []]])
    end

    it "keeps only the join conditions of a FULL JOIN's ON, where both sides are preserved and nullable" do
      sql = "SELECT 1 FROM public.orders o FULL JOIN public.customers c " \
            "ON o.customer_id = c.id AND o.status = 1 AND c.region = 5 WHERE o.region IS NULL"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["customers", %w[id], []]])
    end

    it "counts strict WHERE filters on both sides of a FULL JOIN" do
      sql = "SELECT 1 FROM public.orders o FULL JOIN public.customers c ON o.customer_id = c.id " \
            "WHERE o.region = 2 AND c.name = 'x'"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["orders", %w[customer_id region], []],
                                                ["orders", %w[region], []], ["customers", %w[id], []],
                                                ["customers", %w[id name], []], ["customers", %w[name], []]])
    end

    it "treats every table under the nullable side as nullable, and keeps an inner join's ON there" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN " \
            "(public.orders o JOIN public.orders p ON p.parent_id = o.id AND p.status = 1) ON o.customer_id = c.id " \
            "WHERE p.region IS NULL AND o.total IS NULL AND c.name = 'x'"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["customers", %w[id], []],
                                                 ["customers", %w[id name], []],
                                                 ["customers", %w[name], []],
                                                 ["orders", %w[customer_id], []],
                                                 ["orders", %w[customer_id id], []],
                                                 ["orders", %w[status], []],
                                                 ["orders", %w[status parent_id], []]
                                               ])
    end

    it "counts a strict conjunct in a higher ON on a table a lower LEFT JOIN made nullable" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
            "JOIN public.customers i ON i.id = c.id AND o.region = 7"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[id], []], ["orders", %w[customer_id], []],
                                                ["orders", %w[customer_id region], []], ["orders", %w[region], []]])
    end

    it "counts a WHERE IS NULL on the preserved side of a LEFT JOIN" do
      sql = "SELECT 1 FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id WHERE c.name IS NULL"

      expect(keys(generate(sql, stats))).to eq([["customers", %w[name], []], ["customers", %w[name id], []],
                                                ["orders", %w[customer_id], []]])
    end

    it "counts a WHERE IS NULL on the preserved side of a RIGHT JOIN" do
      sql = "SELECT 1 FROM public.orders o RIGHT JOIN public.customers c ON o.customer_id = c.id WHERE c.name IS NULL"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []], ["customers", %w[name], []],
                                                ["customers", %w[name id], []]])
    end

    it "doesn't resolve schema and table name once the table has an alias" do
      expect(generate("SELECT 1 FROM public.orders o WHERE public.orders.status = 1", stats)).to eq([])
    end

    it "ignores a comparison between two columns of the same table" do
      expect(generate("SELECT 1 FROM public.orders o WHERE o.customer_id = o.parent_id", stats)).to eq([])
    end

    it "gives an unqualified column to the one table that has it" do
      sql = "SELECT name FROM public.orders o JOIN public.customers c ON c.id = o.customer_id WHERE status = 1"

      expect(keys(generate(sql, stats))).to include(["orders", %w[customer_id status], []],
                                                    ["customers", %w[id], %w[name]])
    end

    it "skips an unqualified column that more than one table has, or that no table has" do
      sql = "SELECT 1 FROM public.orders o, public.customers c WHERE region = 1 AND nosuch = 2 AND o.nosuch = 3"

      expect(generate(sql, stats)).to eq([])
    end

    it "gives a self-join's aliases their own candidates and drops the duplicates" do
      sql = "SELECT 1 FROM public.orders a JOIN public.orders b ON b.parent_id = a.id " \
            "WHERE a.status = 1 AND b.status = 1"

      expect(keys(generate(sql, stats))).to eq([
                                                 ["orders", %w[status], []],
                                                 ["orders", %w[status id], []],
                                                 ["orders", %w[status parent_id], []]
                                               ])
    end

    it "skips the tables inside a subquery in FROM, but still counts a join to it" do
      sql = "SELECT s.id FROM public.orders o JOIN (SELECT id FROM public.customers WHERE region = 1) s " \
            "ON s.id = o.customer_id"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[customer_id], []]])
    end

    it "skips the tables inside a CTE or a subquery in WHERE" do
      sql = "WITH c AS (SELECT id FROM public.customers WHERE region = 1) " \
            "SELECT 1 FROM public.orders o WHERE o.status = 1 AND o.customer_id IN (SELECT id FROM c)"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], []]])
    end
  end

  describe "the select list" do
    let(:stats) do
      statistics(table(orders, { "status" => column(6) }, extra: %w[id total]),
                 table(customers, { "id" => column(-1) }, extra: %w[name]))
    end

    it "puts * into INCLUDE as every column of every table" do
      sql = "SELECT * FROM public.orders o JOIN public.customers c ON c.id = o.status"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], %w[id total]], ["customers", %w[id], %w[name]]])
    end

    it "puts t.* into INCLUDE as every column of that table only" do
      sql = "SELECT c.*, o.id FROM public.orders o JOIN public.customers c ON c.id = o.status"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], %w[id]], ["customers", %w[id], %w[name]]])
    end

    it "reads columns inside expressions, in query order, once each" do
      sql = "SELECT sum(total), lower(o.id::text), total + 1 FROM public.orders o WHERE status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], %w[total id]]])
    end

    it "reads every argument of a function" do
      sql = "SELECT coalesce(id, total, region) FROM public.orders WHERE status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], %w[id total]]])
    end

    it "doesn't read the columns of a subquery in the select list" do
      sql = "SELECT (SELECT max(total) FROM public.orders i) FROM public.orders o WHERE o.status = 1"

      expect(keys(generate(sql, stats))).to eq([["orders", %w[status], []]])
    end
  end

  describe "which predicates count" do
    let(:stats) do
      statistics(table(orders, { "a" => column(10), "b" => column(20), "c" => column(30), "d" => column(40),
                                 "e" => column(50), "f" => column(60), "r" => column(-1), "s" => column(-1),
                                 "note" => column(-1) }))
    end

    def equality_columns(where)
      generate("SELECT 1 FROM public.orders WHERE #{where}", stats, max_key_columns: 10).last&.key&.map(&:name)
    end

    it "counts = against a constant, a parameter, or a cast of either, on either side" do
      expect(equality_columns("a = 1 AND 2 = b AND c = $1 AND d = '5'::int AND e = $2::int")).to eq(%w[e d c b a])
    end

    it "counts IN, = ANY, and IS NULL" do
      expect(equality_columns("a IN (1, 2) AND b = ANY($1) AND c = ANY(ARRAY[1, 2]) AND d IS NULL"))
        .to eq(%w[d c b a])
    end

    it "doesn't count <>, NOT IN, IS NOT NULL, or a comparison with an expression" do
      expect(equality_columns("a <> 1 AND b NOT IN (1) AND c IS NOT NULL AND d = e + 1 AND f = now()")).to be_nil
    end

    it "doesn't count a comparison with a cast of a column" do
      expect(equality_columns("a = b::int AND c < d::int")).to be_nil
    end

    it "doesn't count other operators as range predicates" do
      expect(equality_columns("r @> '{1}' AND note ~ 'x' AND s && '{1}'")).to be_nil
    end

    it "doesn't count a star" do
      expect(generate("SELECT 1 FROM public.orders o WHERE o.* IS NULL", stats)).to eq([])
    end

    it "prefers a comparison range column over a prefix LIKE, which a plain btree may not serve" do
      expect(equality_columns("note LIKE 'abc%' AND r > $1")).to eq(%w[r])
      expect(equality_columns("note LIKE 'abc%' AND a = 1")).to eq(%w[a note])
    end

    it "breaks selectivity ties by query order, even with many tied columns" do
      names = (1..50).map { |n| format("c%02d", n) }
      stats = statistics(table(orders, names.to_h { |n| [n, column(10)] }))
      where = names.reverse.map { |n| "#{n} = 1" }.join(" AND ")

      expect(generate("SELECT 1 FROM public.orders WHERE #{where}", stats).last.key.map(&:name))
        .to eq(%w[c50 c49 c48])
    end

    it "keeps query order for many columns with unknown selectivity" do
      names = (1..50).map { |n| format("c%02d", n) }
      stats = statistics(table(orders, {}, extra: names))
      where = names.reverse.map { |n| "#{n} = 1" }.join(" AND ")

      expect(generate("SELECT 1 FROM public.orders WHERE #{where}", stats).last.key.map(&:name))
        .to eq(%w[c50 c49 c48])
    end

    it "doesn't count IN or = ANY with anything but constants" do
      expect(equality_columns("a IN (1, b) AND c = ANY(ARRAY[1, d]) AND e <> ANY($1)")).to be_nil
    end

    it "doesn't count a column under a cast or in an expression" do
      expect(equality_columns("a::text = '1' AND b + 1 = 2 AND lower(note) = 'x'")).to be_nil
    end

    it "ignores predicates under OR or NOT" do
      expect(equality_columns("(a = 1 OR b = 2) AND NOT (c = 3) AND d = 4")).to eq(%w[d])
    end

    it "reads nested ANDs" do
      expect(equality_columns("a = 1 AND (b = 2 AND (c = 3))")).to eq(%w[c b a])
    end

    it "puts one range column after the equality columns, the first in query order" do
      expect(equality_columns("r > 5 AND a = 1 AND s < 3")).to eq(%w[a r])
    end

    it "counts <, <=, >, >=, and BETWEEN as range predicates, on either side" do
      %w[r<1 r<=1 r>1 r>=1 1<r 1>=r].push("r BETWEEN 1 AND 2", "r BETWEEN SYMMETRIC 2 AND 1").each do |where|
        expect(equality_columns(where)).to eq(%w[r]), where
      end
    end

    it "counts LIKE with a constant pattern that doesn't start with a wildcard as a range predicate" do
      expect(equality_columns("note LIKE 'abc%'")).to eq(%w[note])
    end

    it "doesn't count a LIKE that starts with a wildcard or an escape, or isn't a constant, or ILIKE" do
      ["note LIKE '%abc'", "note LIKE '_bc%'", "note LIKE '\\%x'", "note LIKE $1", "note ILIKE 'abc%'",
       "note NOT LIKE 'abc%'", "r NOT BETWEEN 1 AND 2", "r BETWEEN 1 AND s", "note LIKE ''", "r < s",
       "r > now()"].each do |where|
        expect(equality_columns(where)).to be_nil, where
      end
    end

    it "treats a column with both an equality and a range predicate as equality" do
      expect(equality_columns("r > 1 AND b = 1 AND r = 2 AND s > 0")).to eq(%w[r b s])
    end
  end

  describe "the key cap" do
    let(:stats) do
      statistics(table(orders, { "a" => column(10), "b" => column(20), "c" => column(30), "d" => column(40),
                                 "r" => column(-1) }))
    end

    it "caps the key at three columns by default, emitting each prefix" do
      result = generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2 AND c = 3 AND d = 4", stats)

      expect(keys(result).map { |_, key, _| key }).to eq([%w[d], %w[d c], %w[d c b]])
    end

    it "takes a different cap" do
      result = generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2 AND c = 3 AND r > 4", stats,
                        max_key_columns: 4)

      expect(keys(result).map { |_, key, _| key }).to eq([%w[c], %w[c b], %w[c b a], %w[c b a r]])
    end

    it "drops the range column when the equality columns fill the key" do
      result = generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2 AND r > 4", stats, max_key_columns: 2)

      expect(keys(result).map { |_, key, _| key }).to eq([%w[b], %w[b a]])
    end
  end

  describe "ORDER BY" do
    let(:stats) do
      statistics(table(orders, { "a" => column(10), "b" => column(20), "created_at" => column(-1),
                                 "total" => column(-0.5), "r" => column(-1) }, extra: %w[id]))
    end

    def key_for(sql) = generate("SELECT 1 FROM public.orders #{sql}", stats, max_key_columns: 10).last&.key

    it "appends the ORDER BY columns after the equality columns, keeping direction and nulls ordering" do
      expect(key_for("WHERE a = 1 ORDER BY created_at DESC, total NULLS FIRST, id DESC NULLS LAST"))
        .to eq([asc("a"), desc("created_at"), asc("total", nulls: :first), desc("id", nulls: :last)])
    end

    it "reads an explicit ASC as ascending" do
      expect(key_for("WHERE a = 1 ORDER BY created_at ASC")).to eq([asc("a"), asc("created_at")])
    end

    it "pins a column with IN of one item, but not with IN of several or = ANY" do
      expect(key_for("WHERE a IN (1) ORDER BY created_at")).to eq([asc("a"), asc("created_at")])
      expect(key_for("WHERE a IN (1, 2) ORDER BY created_at")).to eq([asc("a")])
      expect(key_for("WHERE a = ANY($1) ORDER BY created_at")).to eq([asc("a")])
    end

    it "doesn't pin a JOIN ... USING column" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c USING (a) ORDER BY o.created_at"
      stats = statistics(self.stats.table(orders), table(customers, { "a" => column(-1) }))

      # With the join column, ORDER BY can't join. Without it, ORDER BY alone makes the key.
      expect(generate(sql, stats)).to eq([btree(orders, %w[a]), btree(orders, %w[created_at]), btree(customers, %w[a])])
    end

    it "leaves ORDER BY out when an unpinned equality column comes after a new column" do
      expect(key_for("WHERE a IN (1, 2) ORDER BY created_at, a")).to eq([asc("a")])
    end

    it "emits two keys when ORDER BY names the range column, but not first" do
      result = generate("SELECT 1 FROM public.orders WHERE r > 5 ORDER BY created_at, r", stats)

      expect(result.map(&:key)).to eq([[asc("r")], [asc("created_at")], [asc("created_at"), asc("r")]])
    end

    it "flips descending ORDER BY columns and nulls first for a backward scan too" do
      expect(key_for("WHERE a IN (1, 2) ORDER BY a DESC, created_at DESC")).to eq([asc("a"), asc("created_at")])
    end

    it "doesn't read a qualified ORDER BY column as an output alias" do
      sql = "SELECT created_at AS o FROM public.orders o WHERE a = 1 ORDER BY o.id DESC"

      expect(generate(sql, stats).last.key).to eq([asc("a"), desc("id")])
      # The alias is the column's own name, so reading the last field would match it.
      sql = "SELECT created_at AS id FROM public.orders o WHERE a = 1 ORDER BY o.id DESC"

      expect(generate(sql, stats).last).to eq(btree(orders, [asc("a"), desc("id")], %w[created_at]))
    end

    it "builds the key from ORDER BY alone when nothing else counts" do
      expect(generate("SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 10", stats))
        .to eq([btree(orders, [desc("created_at")], %w[id])])
    end

    it "drops ORDER BY columns pinned to one value by =" do
      expect(key_for("WHERE a = 1 AND b = 3 ORDER BY b DESC, a, created_at"))
        .to eq([asc("b"), asc("a"), asc("created_at")])
    end

    it "doesn't pin a column tested with IS NULL, which Postgres can't drop from the sort" do
      expect(key_for("WHERE b IS NULL ORDER BY created_at")).to eq([asc("b")])
      expect(key_for("WHERE b IS NULL ORDER BY b, created_at")).to eq([asc("b"), asc("created_at")])
    end

    it "keeps each alias of a self-join apart when reading how its columns are held" do
      sql = "SELECT 1 FROM public.orders x JOIN public.orders y ON y.a = x.b WHERE x.a = 1 ORDER BY y.created_at"

      expect(generate(sql, stats).map { |c| c.key.map(&:name) }).to eq([%w[b], %w[b a], %w[a], %w[created_at]])
    end

    it "leaves ORDER BY out when an ordinal comes at or after a star in the select list" do
      expect(generate("SELECT *, created_at FROM public.orders WHERE a = 1 ORDER BY 2", stats).last.key)
        .to eq([asc("a")])
      expect(generate("SELECT o.*, created_at FROM public.orders o WHERE a = 1 ORDER BY 2 DESC", stats).last.key)
        .to eq([asc("a")])
      expect(generate("SELECT id, *, created_at FROM public.orders WHERE a = 1 ORDER BY 3 DESC", stats).last.key)
        .to eq([asc("a")])
    end

    it "pins a column that one predicate holds to one value, whatever else names it" do
      stats = statistics(self.stats.table(orders), table(customers, { "id" => column(-1) }))
      expected = [btree(orders, %w[a]), btree(orders, %w[a created_at]), btree(customers, %w[id])]

      # The join read first, then the filter, and the other way around.
      ["SELECT 1 FROM public.orders o, public.customers c WHERE o.a = c.id AND o.a = 1 ORDER BY o.created_at",
       "SELECT 1 FROM public.orders o, public.customers c WHERE o.a = 1 AND o.a = c.id ORDER BY o.created_at"]
        .each { |sql| expect(generate(sql, stats)).to eq(expected), sql }
    end

    it "reads an ordinal that comes before any star" do
      expect(generate("SELECT created_at, * FROM public.orders WHERE a = 1 ORDER BY 1 DESC", stats).last.key)
        .to eq([asc("a"), desc("created_at")])
    end

    it "merges the range column into ORDER BY when ORDER BY starts with it" do
      expect(key_for("WHERE a = $1 AND created_at > $2 ORDER BY created_at DESC")).to eq([asc("a"), desc("created_at")])
    end

    it "emits the range key and the ORDER BY key separately when ORDER BY doesn't start with the range column" do
      result = generate("SELECT 1 FROM public.orders WHERE a = 1 AND r > 5 ORDER BY created_at DESC", stats)

      expect(result).to eq([btree(orders, %w[a]), btree(orders, %w[a r]),
                            btree(orders, [asc("a"), desc("created_at")])])
    end

    it "lets an unpinned equality column lead ORDER BY when it's in the same place in the key" do
      # IN has several values, so a is in the key but not pinned. A forward
      # scan gives a, then created_at.
      expect(key_for("WHERE a IN (1, 2) ORDER BY a, created_at DESC")).to eq([asc("a"), desc("created_at")])
    end

    it "flips the ORDER BY columns for a backward scan when the equality columns in ORDER BY are descending" do
      # A backward scan of (a, created_at DESC) gives a DESC, created_at ASC.
      expect(key_for("WHERE a IN (1, 2) ORDER BY a DESC, created_at")).to eq([asc("a"), desc("created_at")])
    end

    it "leaves ORDER BY out when its directions on the equality columns match neither scan direction" do
      expect(key_for("WHERE a IN (1, 2) AND b IN (1, 2) ORDER BY b, a DESC, created_at")).to eq([asc("b"), asc("a")])
      expect(key_for("WHERE a IN (1, 2) ORDER BY a DESC NULLS LAST, created_at")).to eq([asc("a")])
    end

    it "leaves ORDER BY out when it skips an unpinned equality column or puts them in another order" do
      expect(key_for("WHERE a IN (1, 2) ORDER BY created_at")).to eq([asc("a")])
      expect(key_for("WHERE a IN (1, 2) AND b IN (1, 2) ORDER BY a, b, created_at")).to eq([asc("b"), asc("a")])
      expect(key_for("WHERE a IN (1, 2) AND b IN (1, 2) ORDER BY a, created_at")).to eq([asc("b"), asc("a")])
    end

    it "adds nothing when ORDER BY names only equality columns" do
      expect(key_for("WHERE a IN (1, 2) AND b IN (1, 2) ORDER BY b")).to eq([asc("b"), asc("a")])
    end

    it "treats a join column as an unpinned equality column" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.a ORDER BY o.created_at"
      stats = statistics(self.stats.table(orders), table(customers, { "id" => column(-1) }))

      expect(generate(sql, stats))
        .to eq([btree(orders, %w[a]), btree(orders, %w[created_at]), btree(customers, %w[id])])
    end

    it "leaves ORDER BY out when an item is an expression, another table's column, or USING" do
      expect(key_for("WHERE a = 1 ORDER BY created_at, lower(id::text)")).to eq([asc("a")])
      expect(key_for("WHERE a = 1 ORDER BY created_at USING >")).to eq([asc("a")])
      sql = "SELECT 1 FROM public.orders o, public.customers c WHERE o.a = 1 ORDER BY o.created_at, c.id"
      stats = statistics(self.stats.table(orders), table(customers, { "id" => column(-1) }))
      expect(generate(sql, stats).map(&:key)).to eq([[asc("a")]])
    end

    it "reads an ORDER BY ordinal or output alias as the column it names" do
      expect(generate("SELECT id, created_at FROM public.orders WHERE a = 1 ORDER BY 2 DESC", stats).last.key)
        .to eq([asc("a"), desc("created_at")])
      expect(generate("SELECT created_at AS id FROM public.orders WHERE a = 1 ORDER BY id DESC", stats).last.key)
        .to eq([asc("a"), desc("created_at")])
    end

    it "leaves ORDER BY out when an ordinal or alias names an expression" do
      expect(generate("SELECT id + 1 FROM public.orders WHERE a = 1 ORDER BY 1", stats).last.key).to eq([asc("a")])
      expect(generate("SELECT id + 1 AS total FROM public.orders WHERE a = 1 ORDER BY total", stats).last.key)
        .to eq([asc("a")])
    end

    it "caps a key that ORDER BY made long" do
      result = generate("SELECT 1 FROM public.orders WHERE a = 1 AND b = 2 ORDER BY created_at, total", stats)

      expect(result.last.key).to eq([asc("b"), asc("a"), asc("created_at")])
    end
  end

  describe "INCLUDE" do
    let(:stats) do
      statistics(table(orders, { "a" => column(10), "b" => column(20) }, extra: %w[id total region]))
    end

    it "holds the select-list and GROUP BY columns that aren't in each candidate's own key" do
      sql = "SELECT a, sum(total) FROM public.orders WHERE a = 1 AND b = 2 GROUP BY a, region"

      expect(generate(sql, stats)).to eq([btree(orders, %w[b], %w[a total region]),
                                          btree(orders, %w[b a], %w[total region])])
    end

    it "leaves out WHERE and HAVING columns that aren't in the key" do
      sql = "SELECT 1 FROM public.orders WHERE a = 1 AND (id = 1 OR id = 2) GROUP BY b HAVING max(region) = 'x'"

      expect(generate(sql, stats)).to eq([btree(orders, %w[a], %w[b])])
    end
  end

  describe "BRIN" do
    def stats(correlation:, reltuples: 1_000_000)
      statistics(table(orders, { "a" => column(10), "created_at" => column(-1, correlation:),
                                 "r" => column(-1, correlation: 0.95) }, extra: %w[id], reltuples:))
    end

    def brins(sql, stats, **limits) = generate(sql, stats, **limits).select { |c| c.access_method == :brin }

    let(:range_sql) { "SELECT id FROM public.orders WHERE a = 1 AND created_at > $1" }

    it "adds a single-column BRIN on a well-correlated range column of a large table, after the btrees" do
      result = generate(range_sql, stats(correlation: 0.9))

      expect(result).to eq([btree(orders, %w[a], %w[id]), btree(orders, %w[a created_at], %w[id]),
                            brin(orders, "created_at")])
      expect(result.last.include).to eq([])
      expect(result.last.sources).to eq(Set[:parse])
    end

    it "counts negative correlation by its absolute value" do
      expect(brins(range_sql, stats(correlation: -0.9))).to eq([brin(orders, "created_at")])
    end

    it "leaves BRIN out below the correlation threshold, or when correlation is nil" do
      expect(brins(range_sql, stats(correlation: 0.8999))).to eq([])
      expect(brins(range_sql, stats(correlation: -0.8999))).to eq([])
      expect(brins(range_sql, stats(correlation: nil))).to eq([])
    end

    it "leaves BRIN out below the row threshold" do
      expect(brins(range_sql, stats(correlation: 0.99, reltuples: 1_000_000))).to eq([brin(orders, "created_at")])
      expect(brins(range_sql, stats(correlation: 0.99, reltuples: 999_999))).to eq([])
    end

    it "takes other thresholds" do
      expect(brins(range_sql, stats(correlation: 0.5, reltuples: 10), brin_min_correlation: 0.5,
                                                                      brin_min_reltuples: 10))
        .to eq([brin(orders, "created_at")])
      expect(brins(range_sql, stats(correlation: 0.95), brin_min_correlation: 0.96)).to eq([])
      expect(brins(range_sql, stats(correlation: 0.95), brin_min_reltuples: 1_000_001)).to eq([])
    end

    it "leaves BRIN out for an equality column or a column without statistics" do
      expect(brins("SELECT 1 FROM public.orders WHERE r = 1", stats(correlation: 0.99))).to eq([])
      expect(brins("SELECT 1 FROM public.orders WHERE id > 1", stats(correlation: 0.99))).to eq([])
    end

    it "considers every range column, not only the one in the key" do
      result = generate("SELECT 1 FROM public.orders WHERE created_at > $1 AND r < $2", stats(correlation: 0.99))

      expect(result).to eq([btree(orders, %w[created_at]), brin(orders, "created_at"), brin(orders, "r")])
    end
  end

  describe "the trust boundary" do
    let(:sentinel) { "QUAACK_SENTINEL_7f3a" }
    let(:stats) do
      statistics(table(orders, { "status" => column(6), "note" => column(-1), "created_at" => column(-1) },
                       extra: %w[id]))
    end

    # Everything a candidate can show: its DDL, inspect, and every member.
    def leaks?(candidates) = candidates.any? { |c| [c.to_ddl, c.inspect, c.to_h.to_s].join.include?(sentinel) }

    it "never puts a literal from the query into a candidate" do
      sql = "SELECT id, '#{sentinel}' AS x FROM public.orders WHERE status = '#{sentinel}' " \
            "AND note LIKE '#{sentinel}%' AND created_at BETWEEN '#{sentinel}' AND '#{sentinel}' " \
            "AND id IN ('#{sentinel}') ORDER BY created_at"
      result = generate(sql, stats)

      expect(result.size).to be >= 3
      expect(leaks?(result)).to be(false)
    end

    it "catches a planted sentinel, so the check above works" do
      planted = Quaack::Enclave::IndexCandidate.new(table: orders, key: ["status"], predicate: "note = '#{sentinel}'",
                                                    sources: [:parse])

      expect(leaks?([planted])).to be(true)
    end

    it "never puts a literal from the query into an error" do
      ["SELECT '#{sentinel}' FROM orders", "SELECT '#{sentinel}'; SELECT 1",
       "DELETE FROM public.orders WHERE note = '#{sentinel}'",
       "SELECT '#{sentinel}' UNION SELECT '#{sentinel}'", "SELECT '#{sentinel}' INTO public.x",
       "WITH d AS (DELETE FROM public.orders WHERE note = '#{sentinel}' RETURNING 1) SELECT 1"].each do |sql|
        expect { generate(sql, stats) }.to raise_error(StandardError) { |e| expect(e.message).not_to include(sentinel) }
      end
    end
  end

  describe "the README example" do
    let(:stats) do
      statistics(
        table(orders, { "status" => column(6, correlation: 0.21), "created_at" => column(-0.94, correlation: 0.99),
                        "customer_id" => column(100_000) }, extra: %w[id total], reltuples: 5_000_000),
        table(customers, { "id" => column(-1), "name" => column(-1, null_frac: 0.02, correlation: 0.01) })
      )
    end

    it "proposes the join-led keys, then the keys without the join, then BRIN" do
      sql = "SELECT o.id, o.total, c.name FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "WHERE o.status = $1 AND o.created_at > $2 AND c.name LIKE $3 ORDER BY o.created_at DESC LIMIT 50"

      expect(generate(sql, stats)).to eq([
                                           btree(orders, %w[customer_id], %w[id total]),
                                           btree(orders, %w[customer_id status], %w[id total]),
                                           btree(orders, %w[customer_id status created_at], %w[id total]),
                                           btree(orders, %w[status], %w[id total]),
                                           btree(orders, ["status", desc("created_at")], %w[id total]),
                                           brin(orders, "created_at"),
                                           btree(customers, %w[id], %w[name])
                                         ])
    end

    it "proposes status, then created_at descending, without the join" do
      sql = "SELECT o.id FROM public.orders o WHERE o.status = $1 AND o.created_at > $2 " \
            "ORDER BY o.created_at DESC LIMIT 50"

      expect(generate(sql, stats)).to eq([
                                           btree(orders, %w[status], %w[id]),
                                           btree(orders, ["status", desc("created_at")], %w[id]),
                                           brin(orders, "created_at")
                                         ])
    end
  end
end
