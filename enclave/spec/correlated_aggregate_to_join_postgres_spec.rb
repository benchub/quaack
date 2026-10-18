# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' correlated_aggregate_to_join, on a real server:
# what it writes, that its output returns the rows its input does on data
# that would show a wrong transformation, and that it fires only on an
# aggregate it can compute once per group.
RSpec.describe Quaack::Enclave::RewriteRules::CorrelatedAggregateToJoin do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Customer 1 has orders of 10, 20, and 30, so only 30 is above its
  # average, and 20 is its average. Customer 2's one order is its own
  # average. Order 31 has no customer, so its group is NULL in the original
  # and has no partner in the rewrite. Customer 3 has only a pending order,
  # so with the status test it has no group at all.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.customers (id int PRIMARY KEY, name text, big bigint);
      CREATE TABLE public.orders (id int PRIMARY KEY, customer_id int, region int, status text NOT NULL,
                                  total int, weight float8, note text);
      INSERT INTO public.customers VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3), (4, 'd', 4);
      INSERT INTO public.orders VALUES
        (11, 1, 1, 'shipped', 10, 1.5, '1'), (12, 1, 1, 'shipped', 20, 2.5, 'x'), (13, 1, 2, 'shipped', 30, 3.5, '3'),
        (21, 2, 1, 'shipped', 5, 1.0, '2'), (31, NULL, 1, 'shipped', 50, 9.0, '4'),
        (41, 3, 1, 'pending', 70, 4.0, '5');
      CREATE FUNCTION public.shout(text) RETURNS text VOLATILE LANGUAGE sql AS 'SELECT upper($1)';
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def rewritten(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    rule.rewrites(PgQuery.parse(redacted.sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, map)
    name = "quaack_aggregate_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    binding.execute(conn, name).values
  ensure
    conn.exec("DEALLOCATE ALL")
  end

  # The original's rows, once the rewrite has been checked to return the
  # same multiset of them.
  def same_rows(sql, rewrite)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    expected = rows(redacted.sql, redacted.placeholder_map)
    expect(rows(rewrite, redacted.placeholder_map).sort).to eq(expected.sort)
    expected.sort
  end

  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  average = "(SELECT avg(o2.total) FROM public.orders o2 WHERE o2.customer_id = o.customer_id)"
  grouped = "(SELECT o2.customer_id, avg(o2.total) AS quaack_agg FROM public.orders o2 " \
            "GROUP BY o2.customer_id) quaack_agg_1"

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["correlated_aggregate_to_join",
       "A WHERE condition that compares with a correlated avg, sum, min, or max subquery joins a derived " \
       "table that computes the aggregate once for each group instead."]
    )
  end

  it "joins a grouped derived table in place of a correlated average, with nothing to rely on" do
    sql = "SELECT o.id FROM public.orders o WHERE o.id > 0 AND o.total > #{average}"
    found = rule.rewrites(PgQuery.parse(Quaack::Enclave::Redaction.query(PgQuery.parse(sql)).sql), catalog)

    expect(found.map(&:assumptions)).to eq([[]])
    rewrite = Quaack::Enclave::Deparse.faithfully(found.first.tree)
    expect(rewrite).to eq("SELECT o.id FROM public.orders o, #{grouped} WHERE o.id > $1 AND " \
                          "o.total > quaack_agg_1.quaack_agg AND quaack_agg_1.customer_id = o.customer_id")
    expect(same_rows(sql, rewrite)).to eq([["13"]])
  end

  it "takes the subquery on the left, and keeps an operator such as >=" do
    sql = "SELECT o.id FROM public.orders o WHERE #{average} <= o.total"
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT o.id FROM public.orders o, #{grouped} WHERE " \
                           "quaack_agg_1.quaack_agg <= o.total AND quaack_agg_1.customer_id = o.customer_id"])
    expect(same_rows(sql, rewrite.first)).to eq([["12"], ["13"], ["21"], ["41"]])
  end

  it "moves the subquery's own conditions into the derived table, and groups by every correlation" do
    sql = "SELECT o.id FROM public.orders o WHERE o.total >= (SELECT max(o2.total) FROM public.orders o2 " \
          "WHERE o.customer_id = o2.customer_id AND o2.status = 'shipped' AND o2.region = o.region)"
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT o.id FROM public.orders o, (SELECT o2.customer_id, o2.region, " \
                           "max(o2.total) AS quaack_agg FROM public.orders o2 WHERE o2.status = $1 " \
                           "GROUP BY o2.customer_id, o2.region) quaack_agg_1 WHERE " \
                           "o.total >= quaack_agg_1.quaack_agg AND quaack_agg_1.customer_id = o.customer_id " \
                           "AND quaack_agg_1.region = o.region"])
    expect(same_rows(sql, rewrite.first)).to eq([["12"], ["13"], ["21"]])
  end

  it "correlates with a joined table, and keeps a GROUP BY of the outer query's" do
    sql = "SELECT c.name, count(*) FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
          "WHERE o.total < (SELECT sum(o2.total) FROM public.orders o2 WHERE o2.customer_id = c.id) GROUP BY c.name"
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT c.name, count(*) FROM public.customers c JOIN public.orders o ON " \
                           "o.customer_id = c.id, (SELECT o2.customer_id, sum(o2.total) AS quaack_agg FROM " \
                           "public.orders o2 GROUP BY o2.customer_id) quaack_agg_1 WHERE o.total < " \
                           "quaack_agg_1.quaack_agg AND quaack_agg_1.customer_id = c.id GROUP BY c.name"])
    expect(same_rows(sql, rewrite.first)).to eq([%w[a 3]])
  end

  it "takes min over a text column, and an ORM's quoted, unaliased tables" do
    sql = qualified('SELECT "orders".* FROM "orders" WHERE "orders"."note" = (SELECT MIN("o2"."note") ' \
                    'FROM "orders" "o2" WHERE "o2"."customer_id" = "orders"."customer_id")')
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT orders.* FROM public.orders, (SELECT o2.customer_id, min(o2.note) AS quaack_agg " \
                           "FROM public.orders o2 GROUP BY o2.customer_id) quaack_agg_1 WHERE orders.note = " \
                           "quaack_agg_1.quaack_agg AND quaack_agg_1.customer_id = orders.customer_id"])
    expect(same_rows(sql, rewrite.first).map(&:first)).to eq(%w[11 21 41])
  end

  it "rewrites two such conditions, each with its own derived table" do
    sql = "SELECT o.id FROM public.orders o WHERE o.total > #{average} AND o.total <= " \
          "(SELECT max(o3.total) FROM public.orders o3 WHERE o3.customer_id = o.customer_id)"
    rewrite = rewritten(sql)

    expect(rewrite.first).to include("quaack_agg_1", "quaack_agg_2")
    expect(same_rows(sql, rewrite.first)).to eq([["13"]])
  end

  {
    "a count, which is 0 over no rows" => "o.total > (SELECT count(*) FROM public.orders o2 " \
                                          "WHERE o2.customer_id = o.customer_id)",
    "a count of a column" => "o.total > (SELECT count(o2.total) FROM public.orders o2 " \
                             "WHERE o2.customer_id = o.customer_id)",
    "an aggregate of an expression" => "o.total > (SELECT avg(o2.total + 1) FROM public.orders o2 " \
                                       "WHERE o2.customer_id = o.customer_id)",
    "a sum of a float column, which can overflow on a group the original never reads" =>
      "o.weight > (SELECT sum(o2.weight) FROM public.orders o2 WHERE o2.customer_id = o.customer_id)",
    "an aggregate with DISTINCT" => "o.total > (SELECT avg(DISTINCT o2.total) FROM public.orders o2 " \
                                    "WHERE o2.customer_id = o.customer_id)",
    "an aggregate with FILTER" => "o.total > (SELECT avg(o2.total) FILTER (WHERE o2.total > 1) FROM public.orders o2 " \
                                  "WHERE o2.customer_id = o.customer_id)",
    "a subquery with no correlation" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 WHERE o2.total > 1)",
    "a correlation of two types" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                    "WHERE o2.customer_id = c.big)",
    "a correlation that isn't an equality" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                              "WHERE o2.customer_id < o.customer_id)",
    "a correlation under an OR" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                   "WHERE o2.customer_id = o.customer_id OR o2.region = o.region)",
    "a bare column, which may be an outer one" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                                  "WHERE o2.customer_id = o.customer_id AND status = 'x')",
    "a condition that can raise on rows the original never reads" =>
      "o.total > (SELECT avg(o2.total) FROM public.orders o2 WHERE o2.customer_id = o.customer_id " \
      "AND o2.note::int > 0)",
    "a nested subquery" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 WHERE o2.customer_id = " \
                           "o.customer_id AND o2.id IN (SELECT 1))",
    "a test other than a comparison, such as a match" => "o.note ~ (SELECT min(o2.note) FROM public.orders o2 " \
                                                         "WHERE o2.customer_id = o.customer_id)",
    "a subquery with GROUP BY" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                  "WHERE o2.customer_id = o.customer_id GROUP BY o2.region)",
    "a subquery with LIMIT" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                               "WHERE o2.customer_id = o.customer_id LIMIT 1)",
    "a subquery of two tables" => "o.total > (SELECT avg(o2.total) FROM public.orders o2, public.customers c2 " \
                                  "WHERE o2.customer_id = o.customer_id)",
    "a volatile call" => "o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                         "WHERE o2.customer_id = o.customer_id) AND public.shout(o.note) = 'X'",
    "a comparison under an OR" => "(o.total > (SELECT avg(o2.total) FROM public.orders o2 " \
                                  "WHERE o2.customer_id = o.customer_id) OR o.id = 1)",
    "a test other than a comparison" => "o.total IS DISTINCT FROM (SELECT avg(o2.total) FROM public.orders o2 " \
                                        "WHERE o2.customer_id = o.customer_id)"
  }.each do |shape, test|
    it "leaves #{shape} alone" do
      expect(rewritten("SELECT o.id FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
                       "WHERE #{test}")).to eq([])
    end
  end

  it "leaves a statement alone whose bare column the derived table's key column would make ambiguous" do
    expect(rewritten("SELECT o.id FROM public.orders o WHERE region > 0 AND o.total > " \
                     "(SELECT avg(o2.total) FROM public.orders o2 WHERE o2.region = o.region)")).to eq([])
  end

  it "leaves a correlation alone whose outer name the subquery's own table hides" do
    sql = "SELECT orders.id FROM public.orders WHERE orders.total > (SELECT avg(orders.total) " \
          "FROM public.orders WHERE orders.customer_id = orders.customer_id)"
    # The subquery's orders.customer_id = orders.customer_id reads only its
    # own table, so it averages every order with a customer: 135 / 5 = 27.
    expect(rows(sql, {})).to contain_exactly(["13"], ["31"], ["41"])
    expect(rewritten(sql)).to eq([])
  end

  it "leaves an outer SELECT with a bare star alone, since the join would add columns" do
    expect(rewritten("SELECT * FROM public.orders o WHERE o.total > #{average}")).to eq([])
  end

  it "leaves a subquery in the select list alone, where a missing group would drop the row" do
    expect(rewritten("SELECT o.id, #{average} FROM public.orders o")).to eq([])
  end
end
