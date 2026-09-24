# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/predicate_atoms"

RSpec.describe Quaack::Enclave::PredicateAtoms do
  def table_name(name, schema: "public") = Quaack::Enclave::TableName.new(schema:, name:)

  let(:orders) { table_name("orders") }
  let(:customers) { table_name("customers") }
  let(:items) { table_name("items") }
  let(:column_names) do
    {
      orders => %w[id customer_id status total created_at note active tags],
      customers => %w[id name email region],
      items => %w[id order_id sku qty]
    }
  end

  def extract(sql) = described_class.extract(PgQuery.parse(sql), column_names:)

  # [kind, operator, negated] for each atom.
  def kinds(sql) = extract(sql).map { |a| [a.kind, a.operator, a.negated] }

  def where(predicate) = "SELECT o.id FROM public.orders o WHERE #{predicate}"

  describe "kinds" do
    it "classifies comparisons with a constant by operator family" do
      expect(kinds(where("o.status = 1 AND o.total < 5 AND 5 <= o.total AND o.total > 1 AND o.total >= 2")))
        .to eq([[:equality, "=", false], [:range, "<", false], [:range, "<=", false],
                [:range, ">", false], [:range, ">=", false]])
    end

    it "treats <> and IS DISTINCT FROM as negated equality, and IS NOT DISTINCT FROM as equality" do
      expect(kinds(where("o.status <> 1 AND o.status != 2 AND o.status IS DISTINCT FROM 3 " \
                         "AND o.status IS NOT DISTINCT FROM 4")))
        .to eq([[:equality, "<>", true], [:equality, "<>", true], [:equality, "IS DISTINCT FROM", true],
                [:equality, "IS NOT DISTINCT FROM", false]])
    end

    it "treats BETWEEN as one range atom, in every form" do
      expect(kinds(where("o.total BETWEEN 1 AND 2 AND o.total NOT BETWEEN 3 AND 4 " \
                         "AND o.total BETWEEN SYMMETRIC 5 AND 6")))
        .to eq([[:range, "BETWEEN", false], [:range, "NOT BETWEEN", true], [:range, "BETWEEN SYMMETRIC", false]])
    end

    it "classifies LIKE and ILIKE, negated or not" do
      expect(kinds(where("o.note LIKE 'a%' AND o.note NOT LIKE 'b%' AND o.note ILIKE 'c%' " \
                         "AND o.note NOT ILIKE 'd%' AND o.note LIKE 'e!%' ESCAPE '!'")))
        .to eq([[:like, "LIKE", false], [:like, "NOT LIKE", true], [:like, "ILIKE", false],
                [:like, "NOT ILIKE", true], [:like, "LIKE", false]])
    end

    it "treats IN lists, = ANY, and <> ALL with constant arrays as IN" do
      expect(kinds(where("o.status IN (1, 2) AND o.status NOT IN (3) AND o.status = ANY('{4,5}') " \
                         "AND o.status = ANY(ARRAY[6, 7]) AND o.status <> ALL(ARRAY[8])")))
        .to eq([[:in, "IN", false], [:in, "NOT IN", true], [:in, "= ANY", false], [:in, "= ANY", false],
                [:in, "<> ALL", true]])
    end

    it "classifies IS NULL and IS NOT NULL" do
      expect(kinds(where("o.note IS NULL AND o.note IS NOT NULL")))
        .to eq([[:null_test, "IS NULL", false], [:null_test, "IS NOT NULL", true]])
    end

    it "counts any column-free expression as the constant side" do
      expect(kinds(where("o.created_at > now() - interval '1 day' AND o.status = 1 + 2 " \
                         "AND o.status IN (1, abs(-2))")))
        .to eq([[:range, ">", false], [:equality, "=", false], [:in, "IN", false]])
    end

    it "classifies what fits no family as other" do
      sql = where("o.active AND o.status < ALL('{1}') AND o.status = ANY(ARRAY[o.id]) AND o.tags @> '{x}' " \
                  "AND o.note SIMILAR TO 'a%' AND o.status = o.id AND o.active IS TRUE AND lower(o.note) " \
                  "AND 1 = 2 AND $1::int IS NULL AND o.status <> o.id")
      expect(kinds(sql))
        .to eq([[:other, nil, false], [:other, "< ALL", false], [:other, "= ANY", false], [:other, "@>", false],
                [:other, "SIMILAR TO", false], [:other, "=", false], [:other, "IS TRUE", false],
                [:other, nil, false], [:other, "=", false], [:other, "IS NULL", false], [:other, "<>", false]])
    end

    it "classifies a subquery test as other, and a comparison with a subquery as other" do
      sql = where("o.status IN (SELECT 1) AND EXISTS (SELECT 1) AND o.total > (SELECT 2) AND o.status = ANY(SELECT 3)")
      expect(kinds(sql).first(4))
        .to eq([[:other, nil, false], [:other, nil, false], [:other, ">", false], [:other, nil, false]])
    end


    it "classifies a comparison between two relations as a join, whatever the operator" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON o.customer_id = c.id " \
            "AND o.total < c.id + 1 AND o.customer_id <> c.id WHERE coalesce(o.status, c.id) = 1"
      expect(kinds(sql)).to eq([[:join, "=", false], [:join, "<", false], [:join, "<>", true], [:join, "=", false]])
    end

    it "keeps an expression on the column side in its family, and marks it not bare" do
      atoms = extract(where("lower(o.note) = 'x' AND o.total::int > 1 AND o.note = 'y' AND o.status IS NULL"))
      expect(atoms.map { |a| [a.kind, a.bare] })
        .to eq([[:equality, false], [:range, false], [:equality, true], [:null_test, true]])
    end

    it "marks a join between two plain columns bare" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON o.customer_id = c.id AND o.total < c.id + 1"
      expect(extract(sql).map(&:bare)).to eq([true, false])
    end
  end

  describe "where atoms come from" do
    def shapes(sql) = extract(sql).map(&:shape)

    it "splits AND, OR, and NOT, and takes the atoms under them" do
      expect(shapes(where("(o.status = 1 OR o.total > 2) AND NOT (o.note IS NULL OR NOT o.active)")))
        .to eq(["o.status = $1", "o.total > $2", "o.note IS NULL", "o.active"])
    end

    it "takes every join's ON clause, at any depth, in query order" do
      sql = "SELECT o.id FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "LEFT JOIN public.items i ON i.order_id = o.id AND i.qty > 1 WHERE o.status = 2"
      expect(shapes(sql)).to eq(["c.id = o.customer_id", "i.order_id = o.id", "i.qty > $1", "o.status = $2"])
    end

    it "takes HAVING and an aggregate's FILTER" do
      sql = "SELECT count(*) FILTER (WHERE o.status = 1) FROM public.orders o GROUP BY o.customer_id " \
            "HAVING sum(o.total) > 2 AND count(*) FILTER (WHERE o.note IS NULL) < 3"
      expect(shapes(sql)).to eq(["o.status = $1", "sum(o.total) > $2",
                                 "count(*) FILTER (WHERE o.note IS NULL) < $3", "o.note IS NULL"])
    end

    it "takes a searched CASE's conditions, in the select list or inside another atom" do
      sql = "SELECT CASE WHEN o.status = 1 THEN 'a' WHEN o.status = 2 OR o.active THEN 'b' END " \
            "FROM public.orders o WHERE CASE WHEN o.total > 3 THEN o.note ELSE 'c' END = 'd'"
      expect(shapes(sql)).to eq(["o.status = $1", "o.status = $3", "o.active",
                                 "CASE WHEN o.total > $5 THEN o.note ELSE $6 END = $7", "o.total > $5"])
    end

    it "takes a simple CASE's WHEN values as equality atoms on its argument" do
      sql = "SELECT CASE o.status WHEN 1 THEN 'a' WHEN 2 THEN 'b' END FROM public.orders o"
      expect(extract(sql).map { |a| [a.kind, a.shape] }).to eq([[:equality, "o.status = $1"], [:equality, "o.status = $3"]])
    end

    it "takes the atoms inside subqueries anywhere, and the subquery test itself" do
      sql = "WITH big AS (SELECT c.id FROM public.customers c WHERE c.region = 'x') " \
            "SELECT (SELECT max(i.qty) FROM public.items i WHERE i.order_id = o.id) " \
            "FROM public.orders o JOIN (SELECT i.order_id FROM public.items i WHERE i.sku LIKE 'y%') s " \
            "ON s.order_id = o.id " \
            "WHERE EXISTS (SELECT 1 FROM public.items i WHERE i.order_id = o.id AND i.qty > 4) " \
            "AND o.customer_id IN (SELECT b.id FROM big b)"
      expect(shapes(sql)).to eq([
                                  "c.region = $1", "i.order_id = o.id", "i.sku LIKE $2", "s.order_id = o.id",
                                  "EXISTS (SELECT $3 FROM public.items i WHERE i.order_id = o.id AND i.qty > $4)",
                                  "i.order_id = o.id", "i.qty > $4",
                                  "o.customer_id IN (SELECT b.id FROM big b)"
                                ])
    end

    it "takes both arms of a set operation" do
      sql = "SELECT o.id FROM public.orders o WHERE o.status = 1 UNION SELECT c.id FROM public.customers c " \
            "WHERE c.region = 'x'"
      expect(shapes(sql)).to eq(["o.status = $1", "c.region = $2"])
    end

    it "skips a bare constant, which TRUE can't replace" do
      sql = "SELECT o.id FROM public.orders o JOIN public.customers c ON true WHERE true AND 1::boolean " \
            "AND o.status = 1"
      expect(shapes(sql)).to eq(["o.status = $4"])
    end
  end

  describe "shapes" do
    def shapes(sql) = extract(sql).map(&:shape)

    it "is the atom's SQL with each constant a placeholder numbered in query order, as PgQuery.normalize numbers them" do
      sql = where("o.status = 7 AND o.note LIKE 'abc%' AND o.total BETWEEN 1 AND 2")
      expect(shapes(sql)).to eq(["o.status = $1", "o.note LIKE $2", "o.total BETWEEN $3 AND $4"])
      expect(PgQuery.normalize(sql)).to include("o.status = $1 AND o.note LIKE $2 AND o.total BETWEEN $3 AND $4")
    end

    it "numbers after the query's own parameters, and keeps them" do
      expect(shapes(where("o.status = $1 AND o.total > 5 AND o.id = $2")))
        .to eq(["o.status = $1", "o.total > $3", "o.id = $2"])
    end

    it "counts constants outside predicates in the numbering" do
      sql = "SELECT 'x', 5 FROM public.orders o WHERE o.status = 9 LIMIT 3"
      expect(shapes(sql)).to eq(["o.status = $3"])
    end

    it "replaces every element of an IN list and an array, keeping the count" do
      expect(shapes(where("o.status IN (1, 2, 3) AND o.status = ANY(ARRAY[4, 5])")))
        .to eq(["o.status IN ($1, $2, $3)", "o.status = ANY(ARRAY[$4, $5])"])
    end

    it "replaces constants under casts, and keeps type modifiers and COLLATE names, which are shape" do
      sql = where("o.note COLLATE \"C\" = 'a'::varchar(12) AND o.created_at > now() - interval '5' minute " \
                  "AND o.total = '-3'::numeric(10, 2)")
      expect(shapes(sql))
        .to eq(["o.note COLLATE \"C\" = $1::varchar(12)", "o.created_at > (now() - $2::interval minute)",
                "o.total = $3::numeric(10, 2)"])
    end

    it "replaces booleans, NULLs, and an ESCAPE character too" do
      expect(shapes(where("o.active = true AND o.note = NULL AND o.note LIKE 'a' ESCAPE '!'")))
        .to eq(["o.active = $1", "o.note = $2", "o.note LIKE pg_catalog.like_escape($3, $4)"])
    end

    it "is the same for the same query every time" do
      sql = where("o.status = 1 AND o.note IS NULL")
      expect(shapes(sql)).to eq(shapes(sql))
      expect(shapes(sql)).to eq(["o.status = $1", "o.note IS NULL"])
    end
  end

  describe "trust boundary" do
    # Every literal position here holds a sentinel. None may reach a shape.
    let(:sentinels) { %w[SENTINEL_TEXT 424242 31337.5 SENTINEL_LIKE SENTINEL_ARRAY SENTINEL_CAST 777001 SENTINEL_SUB] }
    let(:sql) do
      "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id AND c.name = 'SENTINEL_TEXT' " \
        "WHERE o.status = 424242 AND o.total > 31337.5 AND o.note LIKE '%SENTINEL_LIKE%' " \
        "AND o.tags = ANY('{SENTINEL_ARRAY}'::text[]) AND o.created_at < 'SENTINEL_CAST'::date + 777001 " \
        "AND o.status IN (SELECT 1 FROM public.items i WHERE i.sku = 'SENTINEL_SUB') " \
        "AND CASE WHEN o.note = 'SENTINEL_TEXT' THEN o.status ELSE 424242 END = 424242"
    end

    it "never puts a literal in a shape" do
      shapes = extract(sql).map(&:shape)
      expect(shapes.size).to be >= 8
      sentinels.each { |s| expect(shapes.grep(/#{Regexp.escape(s)}/)).to be_empty, "#{s} leaked into a shape" }
    end

    it "never puts a literal in an atom at all" do
      dump = extract(sql).map(&:inspect).join("\n")
      sentinels.each { |s| expect(dump).not_to include(s) }
    end

    it "uses a check that sees a planted literal" do
      # The same check on the atoms' unredacted SQL finds every sentinel, so
      # the checks above would catch a leak.
      unredacted = PgQuery.deparse(PgQuery.parse(sql).tree)
      sentinels.each { |s| expect(unredacted).to include(s) }
    end
  end
end
