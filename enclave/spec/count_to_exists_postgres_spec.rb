# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' count_to_exists, on a real server: what it writes, that
# its output returns the rows its input does on data that would show a wrong
# transformation, that it asks the literal oracle whether the constant is 0
# or 1, and that it fires only on a count it can turn into an existence test.
RSpec.describe Quaack::Enclave::RewriteRules::CountToExists do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Gold customers 1, 5, and 6 have a shipped order: 1 has two, so a test of
  # the count against 1 tells the two apart. 2's only order is pending, and 3
  # has none. Silver customer 4 has a shipped order. Of the shipped orders,
  # only 11, 41, and 61 have a note, so a count of the note isn't a count of
  # the rows: 5's one shipped order has none. ship_to is a row: 51's has
  # every field NULL, which count counts and IS NOT NULL calls NULL, and
  # 61's is NULL. Order 12 is the only one with an item.
  before do
    conn.exec(<<~SQL)
      CREATE TYPE public.address AS (street text, city text);
      CREATE TABLE public.customers (id int PRIMARY KEY, tier text NOT NULL, email text, note text);
      CREATE TABLE public.orders (id int PRIMARY KEY, customer_id int, status text NOT NULL, note text,
                                  ship_to public.address);
      CREATE TABLE public.items (id int PRIMARY KEY, order_id int, note text);
      INSERT INTO public.customers VALUES
        (1, 'gold', 'one@example.com', 'n1'), (2, 'gold', 'two@example.com', NULL),
        (3, 'gold', NULL, NULL), (4, 'silver', 'four@example.com', NULL),
        (5, 'gold', 'five@example.com', NULL), (6, 'gold', 'six@example.com', NULL);
      INSERT INTO public.orders VALUES
        (11, 1, 'shipped', 'a', ROW('Main', 'Town')), (12, 1, 'shipped', NULL, ROW('Main', 'Town')),
        (21, 2, 'pending', 'b', NULL), (41, 4, 'shipped', 'c', NULL),
        (51, 5, 'shipped', NULL, ROW(NULL, NULL)), (61, 6, 'shipped', 'd', NULL);
      INSERT INTO public.items VALUES (1, 12, 'x');
      CREATE FUNCTION public.shout(text) RETURNS text VOLATILE LANGUAGE sql AS 'SELECT upper($1)';
      CREATE FUNCTION public.label(public.orders) RETURNS public.address IMMUTABLE LANGUAGE sql
        AS 'SELECT ROW(NULL, NULL)::public.address';
    SQL
  end

  after do
    conn.close
    production.drop
  end

  # The redacted SQL, and the literal oracle over its placeholders.
  def literals_for(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    [redacted, Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)]
  end

  # The rule's rewrites of sql, redacted as a run redacts it, each as SQL.
  def rewritten(sql)
    redacted, literals = literals_for(sql)
    rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, map)
    name = "quaack_count_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    binding.execute(conn, name).values
  ensure
    conn.exec("DEALLOCATE ALL")
  end

  # The original's rows, in the server's order, once the rewrite has been
  # checked to return the same multiset of them, bound with the original's
  # literals.
  def same_rows(sql, rewrite)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    expected = rows(redacted.sql, redacted.placeholder_map)
    expect(rows(rewrite, redacted.placeholder_map).sort).to eq(expected.sort)
    expected
  end

  # As input qualifies it.
  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  def shipped(test) = "SELECT c.id FROM public.customers c WHERE c.tier = 'gold' AND #{test} ORDER BY c.id"

  count = "(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id AND o.status = 'shipped')"
  inner = "SELECT 1 FROM public.orders o WHERE o.customer_id = c.id AND o.status = $2"
  let(:count) { count }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["count_to_exists",
       "A count subquery compared so that it asks only whether any row matches, as count(*) > 0 or " \
       "count(*) = 0 does, becomes EXISTS or NOT EXISTS."]
    )
  end

  it "makes count(*) > 0 an EXISTS of the subquery, with nothing to rely on" do
    sql = shipped("#{count} > 0")
    redacted, literals = literals_for(sql)
    found = rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals)

    expect(found.map(&:assumptions)).to eq([[]])
    rewrite = Quaack::Enclave::Deparse.faithfully(found.first.tree)
    expect(rewrite).to eq("SELECT c.id FROM public.customers c WHERE c.tier = $1 AND EXISTS (#{inner}) ORDER BY c.id")
    expect(same_rows(sql, rewrite)).to eq([["1"], ["5"], ["6"]])
  end

  {
    "#{count} > 0" => true, "#{count} >= 1" => true, "#{count} <> 0" => true, "#{count} != 0" => true,
    "0 < #{count}" => true, "1 <= #{count}" => true, "0 <> #{count}" => true,
    "#{count} = 0" => false, "#{count} <= 0" => false, "#{count} < 1" => false,
    "0 = #{count}" => false, "0 >= #{count}" => false, "1 > #{count}" => false,
    "#{count} OPERATOR(pg_catalog.>) 0" => true
  }.each do |test, exists|
    it "makes #{test.sub(count, "count")} #{exists ? "EXISTS" : "NOT EXISTS"}" do
      sql = shipped(test)
      rewrite = rewritten(sql)
      # The threshold is $2 when it's written first.
      body = test.start_with?("(") ? inner : inner.sub("$2", "$3")

      expect(rewrite).to eq(["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND " \
                             "#{"NOT " unless exists}EXISTS (#{body}) ORDER BY c.id"])
      expect(same_rows(sql, rewrite.first)).to eq(exists ? [["1"], ["5"], ["6"]] : [["2"], ["3"]])
    end
  end

  [
    "#{count} > 1", "#{count} >= 0", "#{count} >= 2", "#{count} <> 1", "#{count} = 1", "#{count} <= 1",
    "#{count} < 0", "#{count} < 2", "1 < #{count}", "0 <= #{count}", "0 > #{count}", "2 > #{count}",
    "#{count} > 0.5", "#{count} > NULL"
  ].each do |test|
    it "leaves #{test.sub(count, "count")} alone, since the oracle says its constant isn't the one it needs" do
      expect(rewritten(shipped(test))).to eq([])
    end
  end

  it "takes the hand-written scope of an ORM: unaliased, quoted tables, and COUNT in capitals" do
    sql = qualified('SELECT "customers".* FROM "customers" WHERE (SELECT COUNT(*) FROM "orders" ' \
                    'WHERE "orders"."customer_id" = "customers"."id") > 0 ORDER BY "customers"."id"')
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT customers.* FROM public.customers WHERE EXISTS (SELECT 1 FROM public.orders " \
                           "WHERE orders.customer_id = customers.id) ORDER BY customers.id"])
    expect(same_rows(sql, rewrite.first).map(&:first)).to eq(%w[1 2 4 5 6])
  end

  it "takes pg_catalog's count by name, and an uncorrelated subquery" do
    sql = "SELECT c.id FROM public.customers c WHERE " \
          "(SELECT pg_catalog.count(*) FROM public.orders o WHERE o.status = 'lost') = 0 ORDER BY c.id"
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT c.id FROM public.customers c WHERE " \
                           "NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.status = $1) ORDER BY c.id"])
    expect(same_rows(sql, rewrite.first).size).to eq(6)
  end

  describe "a count of a column" do
    it "adds that the column is not null to the subquery's WHERE" do
      sql = shipped("(SELECT count(o.note) FROM public.orders o WHERE o.customer_id = c.id " \
                    "AND o.status = 'shipped') > 0")
      rewrite = rewritten(sql)

      expect(rewrite).to eq(["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND EXISTS (#{inner} " \
                             "AND o.note IS NOT NULL) ORDER BY c.id"])
      expect(same_rows(sql, rewrite.first)).to eq([["1"], ["6"]])
    end

    it "adds it to a subquery with no WHERE, and with an OR for its WHERE" do
      no_where = rewritten(shipped("(SELECT count(o.note) FROM public.orders o) = 0"))
      either = shipped("(SELECT count(o.note) FROM public.orders o WHERE o.customer_id = c.id " \
                       "OR o.status = 'pending') = 0")

      expect(no_where).to eq(["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND NOT EXISTS (SELECT 1 " \
                              "FROM public.orders o WHERE o.note IS NOT NULL) ORDER BY c.id"])
      expect(rewritten(either)).to eq(["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND NOT EXISTS " \
                                       "(SELECT 1 FROM public.orders o WHERE (o.customer_id = c.id OR " \
                                       "o.status = $2) AND o.note IS NOT NULL) ORDER BY c.id"])
      expect(same_rows(either, rewritten(either).first)).to eq([])
    end

    it "takes a bare column that only one of the subquery's tables has, though an outer table has it too" do
      sql = shipped("(SELECT count(note) FROM public.orders o WHERE o.customer_id = c.id " \
                    "AND o.status = 'shipped') > 0")
      rewrite = rewritten(sql)

      expect(rewrite).to eq(["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND EXISTS (#{inner} " \
                             "AND note IS NOT NULL) ORDER BY c.id"])
      expect(same_rows(sql, rewrite.first)).to eq([["1"], ["6"]])
    end

    {
      "a column of the outer query" => "count(c.note)",
      "a bare column only the outer query has" => "count(email)",
      "a bare column two of the subquery's tables have" => "count(note)",
      "a bare column none of them has" => "count(missing)",
      "a whole row" => "count(o)",
      "a star of a table" => "count(o.*)",
      "a column of a row type, whose IS NOT NULL tests every field" => "count(o.ship_to)",
      "a function of the row, called as a column, that returns a row" => "count(o.label)",
      "an expression" => "count(o.note || 'x')",
      "a placeholder" => "count(1)",
      "nothing" => "count()",
      "DISTINCT" => "count(DISTINCT o.note)",
      "an ORDER BY" => "count(o.note ORDER BY o.id)",
      "a FILTER" => "count(*) FILTER (WHERE o.note IS NULL)",
      "a window" => "count(*) OVER ()"
    }.each do |what, call|
      it "leaves alone a count of #{what}" do
        from = call == "count(note)" ? "public.orders o JOIN public.items i ON i.order_id = o.id" : "public.orders o"
        expect(rewritten(shipped("(SELECT #{call} FROM #{from} WHERE o.customer_id = c.id) > 0"))).to eq([])
      end
    end

    # The alias makes o.note the row ship_to, and the bare note c's.
    {
      "a column of a table whose alias renames its columns" => "count(o.note)",
      "a bare column of such a table" => "count(note)"
    }.each do |what, call|
      it "leaves alone a count of #{what}" do
        sql = shipped("(SELECT #{call} FROM public.orders o (id, customer_id, status, ship_to, note) " \
                      "WHERE o.customer_id = c.id) > 0")
        expect(rewritten(sql)).to eq([])
      end
    end

    it "leaves alone a bare column beside a FROM item whose columns it can't know" do
      sql = shipped("(SELECT count(note) FROM public.orders o, (SELECT 1 AS n) s WHERE o.customer_id = c.id) > 0")
      expect(rewritten(sql)).to eq([])
    end

    it "would give other rows for a row type's column, or a row function's, with IS NOT NULL" do
      sql = shipped("(SELECT count(o.ship_to) FROM public.orders o WHERE o.customer_id = c.id) > 0")
      wrong = shipped("EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id AND o.ship_to IS NOT NULL)")
      labelled = shipped("(SELECT count(o.label) FROM public.orders o WHERE o.customer_id = c.id) > 0")
      unlabelled = shipped("EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id AND o.label IS NOT NULL)")

      expect(conn.exec(sql).values).to eq([["1"], ["5"]])
      expect(conn.exec(wrong).values).to eq([["1"]])
      expect(conn.exec(labelled).values).to eq([["1"], ["2"], ["5"], ["6"]])
      expect(conn.exec(unlabelled).values).to eq([])
    end
  end

  {
    "another aggregate" => "SELECT max(o.id) FROM public.orders o WHERE o.customer_id = c.id",
    "a count from a schema other than pg_catalog" =>
      "SELECT public.count(*) FROM public.orders o WHERE o.customer_id = c.id",
    "two columns" => "SELECT count(*), 1 FROM public.orders o WHERE o.customer_id = c.id",
    "a GROUP BY" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id GROUP BY o.status",
    "a HAVING" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id HAVING count(*) > 1",
    "a DISTINCT" => "SELECT DISTINCT count(*) FROM public.orders o WHERE o.customer_id = c.id",
    "a WINDOW" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id WINDOW w AS ()",
    "a LIMIT" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id LIMIT 1",
    "an OFFSET" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id OFFSET 1",
    "an ORDER BY" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id ORDER BY 1",
    "a WITH" => "WITH x AS (SELECT o.id FROM public.orders o WHERE o.customer_id = c.id) SELECT count(*) FROM x",
    "a set operation" => "SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id UNION ALL " \
                         "SELECT count(*) FROM public.items i WHERE i.order_id = c.id"
  }.each do |what, subquery|
    it "leaves alone a subquery with #{what}" do
      expect(rewritten(shipped("(#{subquery}) > 0"))).to eq([])
    end
  end

  {
    "a column" => "#{count} > c.id",
    "an expression" => "#{count} > 0 + 0",
    "another subquery" => "#{count} > (SELECT count(*) FROM public.items)",
    "IS DISTINCT FROM" => "#{count} IS DISTINCT FROM 0",
    "BETWEEN" => "#{count} BETWEEN 1 AND 5",
    "an operator of another schema" => "#{count} OPERATOR(public.>) 0",
    "a cast count" => "#{count}::int > 0"
  }.each do |what, test|
    it "leaves alone a count compared with #{what}" do
      expect(rewritten(shipped(test))).to eq([])
    end
  end

  # The oracle reads the '0' as 0, but the query would read it as an array.
  it "leaves alone ARRAY of a count" do
    expect(rewritten(shipped("ARRAY(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id) > '0'")))
      .to eq([])
  end

  it "leaves alone a statement that isn't one SELECT" do
    redacted, literals = literals_for(shipped("#{count} > 0"))

    expect(rule.rewrites(PgQuery.parse("#{redacted.sql}; #{redacted.sql}"), catalog, literals)).to eq([])
  end

  # The review of 20261018-3. As a SubPlan, the correlated count runs its
  # cast only on the purchases of each gold buyer, as the index finds them.
  # As EXISTS or NOT EXISTS, Postgres plans a hash join over every purchase,
  # and the cast meets purchase 8's 'n/a', which is silver buyer 9's.
  describe "a correlated count whose conditions can raise on some rows" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.buyers (id int PRIMARY KEY, tier text NOT NULL);
        CREATE TABLE public.purchases (id int PRIMARY KEY, buyer_id int NOT NULL, status text NOT NULL,
                                       metadata jsonb NOT NULL);
        INSERT INTO public.buyers SELECT i, CASE WHEN i % 2 = 0 THEN 'gold' ELSE 'silver' END
          FROM generate_series(1, 10000) AS i;
        INSERT INTO public.purchases
          SELECT j, 1 + j % 10000, 'paid', jsonb_build_object('total', CASE WHEN j = 8 THEN 'n/a' ELSE (j % 250)::text END)
          FROM generate_series(1, 100000) AS j;
        CREATE INDEX purchases_buyer_id ON public.purchases (buyer_id);
        ANALYZE public.buyers, public.purchases;
      SQL
    end

    cast = "(p.metadata->>'total')::numeric >= 0"
    correlated = "SELECT count(*) FROM public.buyers b WHERE b.tier = 'gold' AND (SELECT count(*) " \
                 "FROM public.purchases p WHERE p.buyer_id = b.id AND #{cast}) "

    it "leaves it alone, since EXISTS can run the conditions on rows no outer row matches" do
      expect(conn.exec("#{correlated}> 0").values).to eq([["5000"]])
      expect(conn.exec("#{correlated}= 0").values).to eq([["0"]])
      %w[> =].each do |operator|
        exists = "SELECT count(*) FROM public.buyers b WHERE b.tier = 'gold' AND #{"NOT " if operator == "="}" \
                 "EXISTS (SELECT 1 FROM public.purchases p WHERE p.buyer_id = b.id AND #{cast})"
        expect { conn.exec(exists) }.to raise_error(PG::InvalidTextRepresentation)
      end

      expect([rewritten("#{correlated}> 0"), rewritten("#{correlated}= 0")]).to eq([[], []])
    end

    it "leaves it alone when the cast is in a join's ON inside the subquery" do
      sql = "SELECT count(*) FROM public.buyers b WHERE b.tier = 'gold' AND (SELECT count(*) " \
            "FROM public.purchases p JOIN public.buyers s ON s.id = p.buyer_id AND #{cast} " \
            "WHERE p.buyer_id = b.id) > 0"

      expect(conn.exec(sql).values).to eq([["5000"]])
      expect(rewritten(sql)).to eq([])
    end

    it "still rewrites a correlated count whose conditions can't raise, and judges an outer count by its rewrite" do
      latest = "(SELECT count(*) FROM public.purchases q WHERE q.buyer_id = p.buyer_id AND q.id > p.id) = 0"
      sql = "SELECT count(*) FROM public.buyers b WHERE b.tier = 'gold' AND (SELECT count(*) " \
            "FROM public.purchases p WHERE p.buyer_id = b.id AND p.status = 'paid' AND #{latest}) > 0"
      rewrite = rewritten(sql)

      expect(rewrite).to eq(["SELECT count(*) FROM public.buyers b WHERE b.tier = $1 AND EXISTS (SELECT 1 " \
                             "FROM public.purchases p WHERE p.buyer_id = b.id AND p.status = $2 AND NOT EXISTS " \
                             "(SELECT 1 FROM public.purchases q WHERE q.buyer_id = p.buyer_id AND q.id > p.id))"])
      expect(same_rows(sql, rewrite.first)).to eq([["5000"]])
    end
  end

  # 20261018-24. An uncorrelated count reads only the rows its index on
  # created_at finds, every fifth, so it never divides by purchase 8's
  # zero qty. EXISTS can plan a seq scan whose filter divides first.
  describe "an uncorrelated count whose conditions can raise on some rows" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.purchases (id int PRIMARY KEY, amount int NOT NULL, qty int NOT NULL,
                                       created_at timestamptz NOT NULL);
        INSERT INTO public.purchases
          SELECT j, CASE WHEN j < 8 THEN 10 ELSE 100 END, CASE WHEN j = 8 THEN 0 ELSE 1 END,
                 CASE WHEN j % 5 = 0 THEN now() ELSE now() - interval '30 days' END
          FROM generate_series(1, 200000) AS j;
        CREATE INDEX purchases_created_at ON public.purchases (created_at);
        ANALYZE public.purchases;
      SQL
    end

    it "leaves it alone, since EXISTS can run the conditions on rows the count never reads" do
      sql = "SELECT (SELECT count(*) FROM public.purchases p WHERE p.amount / p.qty > 30 " \
            "AND p.created_at > now() - interval '7 days') > 0"

      expect(conn.exec(sql).values).to eq([["t"]])
      expect do
        conn.exec("SELECT EXISTS (SELECT 1 FROM public.purchases p WHERE p.amount / p.qty > 30 " \
                  "AND p.created_at > now() - interval '7 days')")
      end.to raise_error(PG::DivisionByZero)
      expect(rewritten(sql)).to eq([])
    end
  end

  it "leaves alone a query that calls a volatile function, in the subquery or anywhere else" do
    in_subquery = "(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id AND random() < 2) > 0"
    expect(rewritten(shipped(in_subquery))).to eq([])
    expect(rewritten(shipped("#{count} > 0 AND public.shout(c.tier) = 'GOLD'"))).to eq([])
  end

  it "needs the literal oracle" do
    redacted, = literals_for(shipped("#{count} > 0"))

    expect(rule.rewrites(PgQuery.parse(redacted.sql), catalog, nil)).to eq([])
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(shipped("#{count} > 0"))
    parse = PgQuery.parse(redacted.sql)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)

    expect(parse.tree).to eq(before)
  end

  describe "positions" do
    it "rewrites a count in the select list, where the test's false shows" do
      sql = "SELECT c.id, #{count} > 0 AS shipped FROM public.customers c ORDER BY c.id"
      rewrite = rewritten(sql)

      expect(rewrite).to eq(["SELECT c.id, EXISTS (#{inner.sub("$2", "$1")}) AS shipped FROM public.customers c " \
                             "ORDER BY c.id"])
      expect(same_rows(sql, rewrite.first)).to eq([%w[1 t], %w[2 f], %w[3 f], %w[4 t], %w[5 t], %w[6 t]])
    end

    it "rewrites a count under an OR, a NOT, and in a CASE" do
      sql = "SELECT c.id, CASE WHEN #{count} = 0 THEN 'none' ELSE 'some' END FROM public.customers c " \
            "WHERE c.tier = 'silver' OR NOT (#{count.sub("shipped", "pending")} > 0) ORDER BY c.id"
      rewrite = rewritten(sql)

      expect(rewrite).to eq(
        ["SELECT c.id, CASE WHEN NOT EXISTS (#{inner.sub("$2", "$1")}) THEN $3 ELSE $4 END " \
         "FROM public.customers c WHERE c.tier = $5 OR NOT EXISTS (#{inner.sub("$2", "$6")}) ORDER BY c.id"]
      )
      expect(same_rows(sql, rewrite.first)).to eq([%w[1 some], %w[3 none], %w[4 some], %w[5 some], %w[6 some]])
    end

    it "rewrites every count of the query in one rewrite, nested ones too" do
      unboxed = "(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id AND " \
                "(SELECT count(*) FROM public.items i WHERE i.order_id = o.id) = 0) > 0"
      sql = shipped("#{unboxed} AND #{count.sub("shipped", "pending")} = 0")
      rewrite = rewritten(sql)

      expect(rewrite).to eq(
        ["SELECT c.id FROM public.customers c WHERE c.tier = $1 AND EXISTS (SELECT 1 FROM public.orders o " \
         "WHERE o.customer_id = c.id AND NOT EXISTS (SELECT 1 FROM public.items i WHERE i.order_id = o.id)) " \
         "AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id AND o.status = $4) " \
         "ORDER BY c.id"]
      )
      expect(same_rows(sql, rewrite.first)).to eq([["1"], ["5"], ["6"]])
    end

    # Redact shares the 0 of the two copies, as Postgres needs, but not a
    # constant inside the subquery, so this one has none.
    it "rewrites every copy alike, so a select list's copy still matches its GROUP BY's" do
      any = "(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id) > 0"
      sql = "SELECT #{any} AS ordered, count(*) FROM public.customers c GROUP BY #{any} ORDER BY 1"
      rewrite = rewritten(sql)

      expect(rewrite).to eq(["SELECT EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id) AS ordered, " \
                             "count(*) FROM public.customers c GROUP BY EXISTS (SELECT 1 FROM public.orders o " \
                             "WHERE o.customer_id = c.id) ORDER BY 1"])
      expect(same_rows(sql, rewrite.first)).to eq([%w[f 1], %w[t 5]])
    end

    it "rewrites a count in a HAVING, a CTE, and a UNION arm" do
      sql = "WITH gold AS (SELECT c.id FROM public.customers c WHERE #{count} > 0) " \
            "SELECT g.id FROM gold g UNION SELECT c.id FROM public.customers c WHERE #{count} = 0 " \
            "UNION SELECT count(*) FROM public.customers c HAVING (SELECT count(*) FROM public.items) >= 1"
      rewrite = rewritten(sql)

      # The deparser puts the first UNION in parentheses.
      expect(rewrite).to eq(
        ["WITH gold AS (SELECT c.id FROM public.customers c WHERE EXISTS (#{inner.sub("$2", "$1")})) " \
         "(SELECT g.id FROM gold g UNION SELECT c.id FROM public.customers c WHERE NOT EXISTS " \
         "(#{inner.sub("$2", "$3")})) UNION SELECT count(*) FROM public.customers c HAVING " \
         "EXISTS (SELECT 1 FROM public.items)"]
      )
      expect(same_rows(sql, rewrite.first).sort).to eq([["1"], ["2"], ["3"], ["4"], ["5"], ["6"]])
    end
  end

  it "never writes a literal, only the redacted query's placeholders" do
    sentinel = production.sentinels.word
    sql = shipped("(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id " \
                  "AND o.status <> '#{sentinel}') > 0")
    rewrite = rewritten(sql)

    expect(sql).to include(sentinel)
    expect(rewrite.size).to eq(1)
    expect(rewrite.first).not_to include(sentinel)
    expect(rewrite.first).to include("o.status <> $2")
  end
end
