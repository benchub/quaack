# frozen_string_literal: true

require "json"
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

    it "doesn't mark an atom with no column bare" do
      expect(extract(where("$1::int IS NULL AND 1 = 2")).map(&:bare)).to eq([false, false])
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
      atoms = extract(sql)
      expect(atoms.map { |a| [a.kind, a.shape] }).to eq([[:equality, "o.status = $1"], [:equality, "o.status = $3"]])
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

  describe "columns" do
    def column(table, refname, name) = described_class::Column.new(table:, refname:, name:)

    # [table, refname, name] for each column of each atom.
    def columns(sql) = extract(sql).map { |a| a.columns.map { |c| [c.table, c.refname, c.name] } }

    it "resolves a column qualified by an alias, by a table name, or by schema and table" do
      sql = "SELECT 1 FROM public.orders o, public.customers WHERE o.status = 1 AND customers.region = 'x' " \
            "AND public.customers.email IS NULL"
      expect(columns(sql)).to eq([[[orders, "o", "status"]], [[customers, "customers", "region"]],
                                  [[customers, "customers", "email"]]])
    end

    it "resolves an unqualified column to the one table that has it" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON customer_id = c.id WHERE region = 'x'"
      expect(columns(sql)).to eq([[[orders, "o", "customer_id"], [customers, "c", "id"]],
                                  [[customers, "c", "region"]]])
    end

    it "leaves an ambiguous or unknown unqualified column unresolved" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON true WHERE id = 1 AND nothing = 2"
      expect(columns(sql)).to eq([[[nil, nil, "id"]], [[nil, nil, "nothing"]]])
    end

    it "resolves a correlated column to the outer query, and makes that a join" do
      sql = "SELECT 1 FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.items i WHERE i.order_id = o.id " \
            "AND order_id = id AND qty = 1)"
      atoms = extract(sql)
      expect(atoms.drop(1).map { |a| [a.kind, a.columns.map { |c| [c.refname, c.name] }] })
        .to eq([[:join, [%w[i order_id], %w[o id]]], [:other, [%w[i order_id], %w[i id]]],
                [:equality, [%w[i qty]]]])
    end

    it "prefers the innermost query for an unqualified column" do
      sql = "SELECT 1 FROM public.customers c WHERE c.id IN (SELECT o.customer_id FROM public.orders o " \
            "WHERE id = 1 AND region = 'x')"
      expect(columns(sql).drop(1)).to eq([[[orders, "o", "id"]], [[customers, "c", "region"]]])
    end

    it "names a subquery's, CTE's, or function's alias with no table" do
      sql = "WITH w AS (SELECT 1 AS a) SELECT 1 FROM w JOIN (SELECT 1 AS b) s ON s.b = w.a " \
            "JOIN generate_series(1, 2) g(n) ON g.n = s.b"
      expect(columns(sql)).to eq([[[nil, "s", "b"], [nil, "w", "a"]], [[nil, "g", "n"], [nil, "s", "b"]]])
      expect(extract(sql).map(&:kind)).to eq(%i[join join])
    end

    it "stops at a frame with a relation whose columns it doesn't know" do
      sql = "SELECT 1 FROM public.orders o WHERE EXISTS (SELECT 1 FROM (SELECT 1 AS x) s WHERE status = 1)"
      expect(columns(sql).last).to eq([[nil, nil, "status"]])
    end

    it "keeps a non-LATERAL subquery in FROM from seeing its siblings, and lets a LATERAL one see them" do
      sql = "SELECT 1 FROM public.orders o, (SELECT 1 FROM public.items i WHERE i.id = customer_id) s, " \
            "LATERAL (SELECT 1 FROM public.items j WHERE j.id = customer_id) t"
      expect(columns(sql)).to eq([[[items, "i", "id"], [nil, nil, "customer_id"]],
                                  [[items, "j", "id"], [orders, "o", "customer_id"]]])
    end

    it "keeps each alias of a self-join apart" do
      sql = "SELECT 1 FROM public.orders a JOIN public.orders b ON a.id = b.customer_id"
      atom = extract(sql).first
      expect([atom.kind, atom.columns]).to eq([:join, [column(orders, "a", "id"), column(orders, "b", "customer_id")]])
    end

    it "counts a column once per atom, and not the columns inside a subquery" do
      sql = where("o.status = o.status + 1 AND o.status IN (SELECT c.id FROM public.customers c)")
      expect(columns(sql).first(2)).to eq([[[orders, "o", "status"]], [[orders, "o", "status"]]])
    end

    it "doesn't let schema and table name a table that has an alias" do
      # The inner orders is aliased, so public.orders.id is the outer one.
      sql = "SELECT 1 FROM public.orders WHERE EXISTS (SELECT 1 FROM public.orders o2 " \
            "WHERE public.orders.id = o2.customer_id)"
      atom = extract(sql).last
      expect([atom.kind, atom.columns.map { |c| [c.refname, c.name] }])
        .to eq([:join, [%w[orders id], %w[o2 customer_id]]])
    end

    it "doesn't let a CTE see the FROM of the SELECT it belongs to" do
      sql = "WITH w AS (SELECT 1 FROM public.items i WHERE i.qty = status) SELECT 1 FROM public.orders o, w"
      expect(columns(sql)).to eq([[[items, "i", "qty"], [nil, nil, "status"]]])
    end

    it "lists the tables an atom touches, once each" do
      sql = "SELECT 1 FROM public.orders o JOIN public.customers c ON o.customer_id = c.id AND o.id = c.id + o.status"
      expect(extract(sql).map(&:tables)).to eq([[orders, customers], [orders, customers]])
    end

    it "raises KeyError, naming the table, when a table has no column names" do
      expect { extract("SELECT 1 FROM public.missing m WHERE m.a = 'SECRET'") }
        .to raise_error(KeyError, /public\.missing/) { |e| expect(e.message).not_to include("SECRET") }
    end
  end

  describe "replacing an atom with TRUE" do
    # The query with each atom in turn replaced by TRUE.
    def replaced(sql)
      parse = PgQuery.parse(sql)
      described_class.extract(parse, column_names:).map { |atom| described_class.with_true(parse, atom) }
    end

    it "replaces just that atom in WHERE" do
      expect(replaced(where("o.status = 1 AND o.total > 2")))
        .to eq(["SELECT o.id FROM public.orders o WHERE true AND o.total > 2",
                "SELECT o.id FROM public.orders o WHERE o.status = 1 AND true"])
    end

    it "replaces it under OR and NOT" do
      expect(replaced(where("o.status = 1 OR NOT o.active")))
        .to eq(["SELECT o.id FROM public.orders o WHERE true OR NOT o.active",
                "SELECT o.id FROM public.orders o WHERE o.status = 1 OR NOT true"])
    end

    it "replaces it in an ON clause, HAVING, and FILTER" do
      sql = "SELECT count(*) FILTER (WHERE o.status = 1) FROM public.orders o " \
            "JOIN public.customers c ON c.id = o.customer_id GROUP BY c.id HAVING count(*) > 2"
      expect(replaced(sql)).to eq(
        [
          "SELECT count(*) FILTER (WHERE true) FROM public.orders o JOIN public.customers c " \
          "ON c.id = o.customer_id GROUP BY c.id HAVING count(*) > 2",
          "SELECT count(*) FILTER (WHERE o.status = 1) FROM public.orders o " \
          "JOIN public.customers c ON true GROUP BY c.id HAVING count(*) > 2",
          "SELECT count(*) FILTER (WHERE o.status = 1) FROM public.orders o " \
          "JOIN public.customers c ON c.id = o.customer_id GROUP BY c.id HAVING true"
        ]
      )
    end

    it "replaces a subquery test, or an atom inside the subquery" do
      sql = where("EXISTS (SELECT 1 FROM public.items i WHERE i.order_id = o.id)")
      expect(replaced(sql))
        .to eq(["SELECT o.id FROM public.orders o WHERE true",
                "SELECT o.id FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.items i WHERE true)"])
    end

    it "replaces a searched CASE's condition" do
      sql = "SELECT CASE WHEN o.status = 1 THEN 'a' ELSE 'b' END FROM public.orders o"
      expect(replaced(sql)).to eq(["SELECT CASE WHEN true THEN 'a' ELSE 'b' END FROM public.orders o"])
    end

    it "turns a simple CASE into a searched one to replace one WHEN" do
      sql = "SELECT CASE o.status WHEN 1 THEN 'a' WHEN 2 THEN 'b' ELSE 'c' END FROM public.orders o"
      expect(replaced(sql)).to eq([
                                    "SELECT CASE WHEN true THEN 'a' WHEN o.status = 2 THEN 'b' ELSE 'c' END " \
                                    "FROM public.orders o",
                                    "SELECT CASE WHEN o.status = 1 THEN 'a' WHEN true THEN 'b' ELSE 'c' END " \
                                    "FROM public.orders o"
                                  ])
    end

    it "replaces an atom nested in another" do
      sql = where("CASE WHEN o.total > 1 THEN o.note END = 'x'")
      expect(replaced(sql)).to eq(["SELECT o.id FROM public.orders o WHERE true",
                                   "SELECT o.id FROM public.orders o WHERE CASE WHEN true THEN o.note END = 'x'"])
    end

    it "leaves the parse it was given alone" do
      parse = PgQuery.parse(where("o.status = 1"))
      described_class.with_true(parse, described_class.extract(parse, column_names:).first)
      expect(parse.deparse).to eq(where("o.status = 1"))
    end

    it "gives the atom's own node, with its real constants, for the value pools" do
      sql = "SELECT CASE o.status WHEN 5 THEN 1 END FROM public.orders o WHERE o.note LIKE 'ab%'"
      parse = PgQuery.parse(sql)
      nodes = described_class.extract(parse, column_names:).map { |atom| described_class.node(parse, atom) }
      expect(nodes.map { |n| PgQuery.deparse_expr(n) }).to eq(["o.status = 5", "o.note LIKE 'ab%'"])
    end
  end

  describe "JOIN ... USING" do
    let(:sql) { "SELECT 1 FROM public.orders o JOIN public.items i USING (id, customer_id)" }

    it "makes each USING column a join atom on the table under each side that has it" do
      atoms = extract("SELECT 1 FROM public.orders o JOIN public.customers c USING (id)")
      expect(atoms.map { |a| [a.kind, a.operator, a.negated, a.bare, a.shape, a.columns] })
        .to eq([[:join, "USING", false, true, "USING (id)",
                 [described_class::Column.new(table: orders, refname: "o", name: "id"),
                  described_class::Column.new(table: customers, refname: "c", name: "id")]]])
    end

    it "leaves a side's column unresolved when more than one table there has it, or none does" do
      atoms = extract("SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
                      "JOIN public.items i USING (id, customer_id)")
      expect(atoms.drop(1).map { |a| a.columns.map { |c| [c.refname, c.name] } })
        .to eq([[[nil, "id"], %w[i id]], [%w[o customer_id], [nil, "customer_id"]]])
    end

    it "quotes a USING column's name when it needs it" do
      column_names[items] += ["Odd Name"]
      column_names[orders] += ["Odd Name"]
      atoms = extract("SELECT 1 FROM public.orders o JOIN public.items i USING (\"Odd Name\")")
      expect(atoms.map(&:shape)).to eq(["USING (\"Odd Name\")"])
    end

    it "can't be replaced by TRUE, since USING also merges the two columns into one" do
      parse = PgQuery.parse("SELECT 1 FROM public.orders o JOIN public.customers c USING (id)")
      atom = described_class.extract(parse, column_names:).first
      expect(atom.replaceable).to be(false)
      expect { described_class.with_true(parse, atom) }.to raise_error(ArgumentError, /USING/)
    end

    it "marks every other atom replaceable" do
      expect(extract(where("o.status = 1 OR o.note IS NULL")).map(&:replaceable)).to eq([true, true])
    end
  end

  describe "constants the deparser needs as literals" do
    # A crash in pg_query's deparser kills the process, so these run in a
    # child process, where a crash is a failed example. The child prints
    # each atom's shape and the query with that atom replaced by TRUE.
    def in_child(sql)
      out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", child_code(sql))
      expect(status).to be_success, "child failed (#{status.inspect}):\n#{err}"
      JSON.parse(out)
    end

    def child_code(sql)
      <<~RUBY
        require "json"
        require "quaack/enclave/predicate_atoms"
        atoms = Quaack::Enclave::PredicateAtoms
        name = ->(n) { Quaack::Enclave::TableName.new(schema: "public", name: n) }
        parse = PgQuery.parse(#{sql.inspect})
        found = atoms.extract(parse, column_names: { name["orders"] => %w[id status note], name["customers"] => %w[id] })
        puts JSON.generate(found.map { |a| [a.shape, atoms.with_true(parse, a)] })
      RUBY
    end

    it "gives a JSON_TABLE path a string placeholder, since the deparser can't take a parameter there" do
      sql = "SELECT 1 FROM public.customers c WHERE EXISTS (SELECT 1 FROM " \
            "JSON_TABLE('[]', '$.SENTINEL_ROW[*]' COLUMNS (x int PATH '$.SENTINEL_COL')) jt WHERE jt.x = c.id)"
      shapes = in_child(sql).map(&:first)
      expect(shapes.first).to include("'$4'").and include("'$5'")
      expect(shapes.join).not_to include("SENTINEL")
      expect(shapes.last).to eq("jt.x = c.id")
    end

    it "does the same for a NESTED PATH" do
      sql = "SELECT 1 FROM public.customers c WHERE (SELECT jt.y FROM JSON_TABLE('[]', '$' COLUMNS " \
            "(NESTED PATH '$.SENTINEL_NESTED' COLUMNS (y int PATH '$'))) jt) = c.id"
      result = in_child(sql)
      expect(result.size).to eq(1)
      expect(result.first.first).not_to include("SENTINEL")
      expect(result.first.last).to eq("SELECT 1 FROM public.customers c WHERE true")
    end

    it "keeps normalize's and IS NORMALIZED's normal form, which is a keyword, not a value" do
      sql = "SELECT 1 FROM public.orders o WHERE normalize(o.note || 'SENTINEL', NFC) = 'SENTINEL' " \
            "AND (o.note || 'SENTINEL') IS NFKD NORMALIZED"
      expect(in_child(sql).map(&:first))
        .to eq(["normalize (o.note || $2, NFC) = $3", "o.note || $4 IS NFKD NORMALIZED"])
    end
  end

  describe "FROM items" do
    def placed(sql) = extract(sql).map { |a| [a.kind, a.columns.map { |c| [c.refname, c.name] }] }

    it "reads the table under TABLESAMPLE" do
      expect(placed("SELECT 1 FROM public.orders o TABLESAMPLE bernoulli(10) WHERE o.status = 1"))
        .to eq([[:equality, [%w[o status]]]])
      sql = "SELECT 1 FROM public.customers c WHERE EXISTS (SELECT 1 FROM public.items i TABLESAMPLE system(1) " \
            "WHERE id = c.id)"
      expect(placed(sql).last).to eq([:join, [%w[i id], %w[c id]]])
    end

    it "treats any other FROM item as a relation with unknown columns, so a column doesn't resolve past it" do
      [
        "EXISTS (SELECT 1 FROM XMLTABLE('/a' PASSING '<a/>' COLUMNS x int PATH 'b') xt WHERE id = 1)",
        "EXISTS (SELECT 1 FROM JSON_TABLE('[]', '$' COLUMNS (x int PATH '$')) jt WHERE id = 1)",
        "EXISTS (SELECT 1 FROM (SELECT 1 AS x) WHERE id = 1)"
      ].each do |predicate|
        expect(placed(where(predicate)).last).to eq([:equality, [[nil, "id"]]]), predicate
      end
    end

    it "names an XMLTABLE or JSON_TABLE by its alias" do
      sql = "SELECT 1 FROM public.orders o, XMLTABLE('/a' PASSING '<a/>' COLUMNS x int PATH 'b') xt " \
            "WHERE xt.x = o.id"
      expect(placed(sql)).to eq([[:join, [%w[xt x], %w[o id]]]])
    end

    it "lets a function in FROM see the FROM it's in, since Postgres makes it LATERAL" do
      sql = "SELECT 1 FROM public.orders o, unnest(ARRAY(SELECT i.qty FROM public.items i WHERE i.order_id = o.id)) u"
      expect(placed(sql)).to eq([[:join, [%w[i order_id], %w[o id]]]])
    end

    it "lets an ON clause see only the join's own inputs" do
      sql = "SELECT 1 FROM public.customers c2, public.orders o JOIN public.customers c ON c.id = o.customer_id " \
            "AND region = 'x'"
      expect(placed(sql).last).to eq([:equality, [%w[c region]]])
    end

    it "names a join by its alias" do
      sql = "SELECT 1 FROM (public.orders o JOIN public.customers c ON o.customer_id = c.id) j WHERE j.status = 1"
      expect(placed(sql).last).to eq([:equality, [%w[j status]]])
    end

    it "takes the innermost relation when an alias is used at two levels" do
      sql = "SELECT 1 FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.items o WHERE o.qty = 1)"
      expect(extract(sql).last.columns).to eq([described_class::Column.new(table: items, refname: "o", name: "qty")])
    end

    it "skips a star, which names no one column" do
      atoms = extract(where("ROW(o.*) IS NULL"))
      expect(atoms.map { |a| [a.kind, a.columns] }).to eq([[:null_test, []]])
    end
  end

  describe "atoms inside an atom that doesn't split" do
    def shapes(sql) = extract(sql).map(&:shape)

    it "takes a CASE's THEN and ELSE results when the CASE is a predicate" do
      expect(shapes(where("CASE WHEN o.active THEN o.status = 1 ELSE o.status = 2 END")))
        .to eq(["CASE WHEN o.active THEN o.status = $1 ELSE o.status = $2 END", "o.active", "o.status = $1",
                "o.status = $2"])
    end

    it "takes the argument of IS TRUE, IS NOT FALSE, and the like" do
      expect(shapes(where("(o.status = 1 OR o.note IS NULL) IS NOT FALSE")))
        .to eq(["(o.status = $1 OR o.note IS NULL) IS NOT FALSE", "o.status = $1", "o.note IS NULL"])
    end

    it "takes comparisons inside function arguments and COALESCE" do
      sql = "SELECT 1 FROM public.orders o GROUP BY o.id HAVING bool_or(o.status = 1) AND coalesce(o.total > 2, false)"
      expect(shapes(sql)).to eq(["bool_or(o.status = $2)", "o.status = $2", "COALESCE(o.total > $3, $4)",
                                 "o.total > $3"])
    end

    it "splits NOT, and takes IS TRUE and subquery tests, inside an atom" do
      sql = where("coalesce(NOT o.active, (o.status = 1) IS TRUE, EXISTS (SELECT 1), false)")
      expect(shapes(sql).drop(1)).to eq(["o.active", "o.status = $1 IS TRUE", "o.status = $1", "EXISTS (SELECT $2)"])
    end

    it "goes back to reading only predicate positions after an atom" do
      expect(shapes(where("o.status = 1 ORDER BY o.total > 5"))).to eq(["o.status = $1"])
    end

    it "replaces a nested atom with TRUE" do
      parse = PgQuery.parse(where("coalesce(o.status = 1, false)"))
      atom = described_class.extract(parse, column_names:).last
      expect(described_class.with_true(parse,
                                       atom)).to eq("SELECT o.id FROM public.orders o WHERE COALESCE(true, false)")
    end

    it "takes atoms nested in a simple CASE's results" do
      sql = where("CASE o.status WHEN 1 THEN (SELECT 1 FROM public.items i WHERE i.qty = 2) END = 1")
      expect(shapes(sql).drop(1)).to eq(["o.status = $1", "i.qty = $3"])
    end

    it "doesn't take comparisons in a select list, even in a subquery inside an atom" do
      expect(shapes("SELECT o.status = 1 FROM public.orders o")).to eq([])
      expect(shapes(where("EXISTS (SELECT o.status = 1)"))).to eq(["EXISTS (SELECT o.status = $1)"])
    end
  end

  describe "input" do
    it "takes only a pg_query parse of one SELECT, and never quotes the SQL" do
      [
        ["SELECT 'SECRET'", "expected a pg_query parse result"],
        [PgQuery.parse("SELECT 'SECRET'; SELECT 2"), "expected exactly one statement"],
        [PgQuery.parse("UPDATE public.orders SET note = 'SECRET'"), "predicate atoms take only a SELECT"]
      ].each do |input, message|
        expect { described_class.extract(input, column_names:) }
          .to raise_error(ArgumentError, message) { |e| expect(e.message).not_to include("SECRET") }
      end
    end

    it "handles an atom deeper than protobuf's default nesting limit" do
      sql = where("o.total #{"+ o.total " * 200}> 1")
      parse = PgQuery.parse(sql)
      atom = described_class.extract(parse, column_names:).first
      expect(atom.shape).to end_with("> $1")
      expect(described_class.with_true(parse, atom)).to eq("SELECT o.id FROM public.orders o WHERE true")
    end
  end

  describe "shapes" do
    def shapes(sql) = extract(sql).map(&:shape)

    it "is the atom's SQL with each constant a placeholder, numbered in query text order" do
      sql = where("o.status = 7 AND o.note LIKE 'abc%' AND o.total BETWEEN 1 AND 2")
      expect(shapes(sql)).to eq(["o.status = $1", "o.note LIKE $2", "o.total BETWEEN $3 AND $4"])
    end

    it "numbers a CTE's constants first, since the CTE comes first in the text" do
      expect(shapes("WITH x AS (SELECT 5 AS a) SELECT 1 FROM public.orders o, x WHERE x.a = 7")).to eq(["x.a = $3"])
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
    let(:sentinels) do
      %w[SENTINEL_TEXT 424242 31337.5 SENTINEL_LIKE SENTINEL_ARRAY SENTINEL_CAST 777001 SENTINEL_SUB 909090 919191
         SENTINEL_ELEM SENTINEL_FUNC SENTINEL_LOW SENTINEL_HIGH SENTINEL_ESCAPE SENTINEL_DISTINCT]
    end
    let(:sql) do
      "SELECT 1 FROM public.orders o JOIN public.customers c ON c.id = o.customer_id AND c.name = 'SENTINEL_TEXT' " \
        "WHERE o.status = 424242 AND o.total > 31337.5 AND o.note LIKE '%SENTINEL_LIKE%' " \
        "AND o.tags = ANY('{SENTINEL_ARRAY}'::text[]) AND o.created_at < 'SENTINEL_CAST'::date + 777001 " \
        "AND o.status IN (SELECT 1 FROM public.items i WHERE i.sku = 'SENTINEL_SUB') " \
        "AND CASE WHEN o.note = 'SENTINEL_TEXT' THEN o.status ELSE 424242 END = 424242 " \
        "AND o.status IN (909090, 919191) AND o.tags = ANY(ARRAY['SENTINEL_ELEM']) " \
        "AND lower(o.note) = lower('SENTINEL_FUNC') AND o.note BETWEEN 'SENTINEL_LOW' AND 'SENTINEL_HIGH' " \
        "AND o.note LIKE 'x' ESCAPE 'SENTINEL_ESCAPE' AND o.note IS DISTINCT FROM 'SENTINEL_DISTINCT'"
    end

    it "never puts a literal in a shape" do
      shapes = extract(sql).map(&:shape)
      expect(shapes.size).to be >= 14
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
