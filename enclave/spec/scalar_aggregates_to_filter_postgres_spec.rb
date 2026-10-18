# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/scalar_aggregates_to_filter"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' scalar_aggregates_to_filter, on a real server:
# uncorrelated scalar aggregate subqueries over one table become one pass,
# with a FILTER each, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::ScalarAggregatesToFilter do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # NULL statuses and amounts, a zero amount, and a status no row has, so
  # a rewrite that lost a FILTER, dropped a NULL, or gave the wrong value
  # over no rows would show.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.orders (id int PRIMARY KEY, customer_id int, status text, amount int, created_at int);
      CREATE TABLE public.customers (id int PRIMARY KEY, name text);
      INSERT INTO public.orders VALUES
        (1, 1, 'pending', 10, 1), (2, 1, 'shipped', 20, 5), (3, 2, 'pending', NULL, 6),
        (4, 2, 'cancelled', 0, 7), (5, 3, NULL, 5, 8), (6, 3, 'shipped', 7, 2), (7, 1, 'pending', 3, 9);
      INSERT INTO public.customers VALUES (1, 'a'), (2, 'b');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def generated(sql)
    original = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, original.placeholder_map)
    rule.rewrites(PgQuery.parse(original.sql), catalog, literals)
  end

  def rewritten(sql) = generated(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

  def rows(sql, map)
    name = "quaack_rule_spec"
    result = Quaack::Enclave::Redaction.binding(sql, map).tap { it.prepare(conn, name) }.execute(conn, name)
    [result.fields, result.values.sort_by(&:to_s)]
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  def runs(sql)
    original = redacted(sql)
    rows(original.sql, original.placeholder_map)
  end

  # sql's only rewrite is expected, which returns sql's rows and column
  # names, and states no assumption.
  def expect_rewrite(sql, expected)
    expect(generated(sql).map { [Quaack::Enclave::Deparse.faithfully(it.tree), it.assumptions] })
      .to eq([[expected, []]])
    expect_same_rows(sql, expected)
  end

  def expect_same_rows(sql, expected)
    want = runs(sql)
    expect(want.last).not_to be_empty
    expect(rows(expected, redacted(sql).placeholder_map)).to eq(want)
  end

  # Each refused query, which Postgres runs, makes no rewrite, and its
  # twin, the same query without what it refuses, makes one.
  def expect_refusals(cases)
    cases.each do |refused, twin|
      expect { runs(refused) }.not_to raise_error, refused
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(twin).size).to eq(1), twin
    end
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["scalar_aggregates_to_filter",
       "Two or more uncorrelated scalar aggregate subqueries over one table become one pass over it, " \
       "with a FILTER for each."]
    )
  end

  it "turns a dashboard's counts into one pass with a FILTER each, and keeps their names" do
    expect_rewrite(
      "SELECT (SELECT count(*) FROM public.orders WHERE status = 'pending') AS pending, " \
      "(SELECT count(*) FROM public.orders WHERE status = 'cancelled') AS cancelled, " \
      "(SELECT count(*) FROM public.orders WHERE status = 'none') AS nothing",
      "SELECT quaack_aggs_1.a_1 AS pending, quaack_aggs_1.a_2 AS cancelled, quaack_aggs_1.a_3 AS nothing " \
      "FROM (SELECT count(*) FILTER (WHERE status = $1) AS a_1, count(*) FILTER (WHERE status = $2) AS a_2, " \
      "count(*) FILTER (WHERE status = $3) AS a_3 FROM public.orders) quaack_aggs_1"
    )
  end

  it "moves the conjuncts every member shares into the WHERE, and gives a member with no rest no FILTER" do
    expect_rewrite(
      "SELECT (SELECT count(*) FROM public.orders o WHERE o.status = 'pending' AND o.created_at >= 5) AS p, " \
      "(SELECT sum(amount) FROM public.orders WHERE orders.created_at >= 5) AS total",
      "SELECT quaack_aggs_1.a_1 AS p, quaack_aggs_1.a_2 AS total FROM (SELECT count(*) FILTER " \
      "(WHERE o.status = $1) AS a_1, sum(amount) AS a_2 FROM public.orders o WHERE o.created_at >= $2) quaack_aggs_1"
    )
  end

  it "keeps a conjunct that holds a different literal in each member's FILTER" do
    expect_rewrite(
      "SELECT (SELECT count(*) FROM public.orders WHERE created_at >= 5) AS a, " \
      "(SELECT count(*) FROM public.orders WHERE created_at >= 7) AS b",
      "SELECT quaack_aggs_1.a_1 AS a, quaack_aggs_1.a_2 AS b FROM (SELECT count(*) FILTER " \
      "(WHERE created_at >= $1) AS a_1, count(*) FILTER (WHERE created_at >= $2) AS a_2 FROM public.orders) " \
      "quaack_aggs_1"
    )
  end

  it "names an unnamed output as Postgres named the subquery, and gives max and sum NULL over no rows" do
    sql = "SELECT (SELECT max(amount) FROM public.orders WHERE status = 'none'), " \
          "(SELECT sum(amount) AS s FROM public.orders WHERE status = 'none'), " \
          "(SELECT count(amount) FROM public.orders WHERE status = 'pending')"
    expect_rewrite(
      sql,
      "SELECT quaack_aggs_1.a_1 AS max, quaack_aggs_1.a_2 AS s, quaack_aggs_1.a_3 AS count FROM (SELECT max(amount) " \
      "FILTER (WHERE status = $1) AS a_1, sum(amount) FILTER (WHERE status = $2) AS a_2, count(amount) FILTER " \
      "(WHERE status = $3) AS a_3 FROM public.orders) quaack_aggs_1"
    )
    expect(runs(sql)).to eq([%w[max s count], [[nil, nil, "2"]]])
  end

  it "adds the pass to a FROM as a comma item, and leaves other items in the select list alone" do
    expect_rewrite(
      "SELECT customers.name, (SELECT count(*) FROM public.orders WHERE status = 'pending') AS p, " \
      "(SELECT min(created_at) FROM public.orders WHERE status IS NULL) AS m FROM public.customers " \
      "WHERE customers.id > 0 ORDER BY customers.name",
      "SELECT customers.name, quaack_aggs_1.a_1 AS p, quaack_aggs_1.a_2 AS m FROM public.customers, " \
      "(SELECT count(*) FILTER (WHERE status = $1) AS a_1, min(created_at) FILTER (WHERE status IS NULL) AS a_2 " \
      "FROM public.orders) quaack_aggs_1 WHERE customers.id > $2 ORDER BY customers.name"
    )
  end

  it "leaves a member that reads another table, or a lone member, as it is" do
    expect(rewritten("SELECT (SELECT count(*) FROM public.orders) AS a, (SELECT count(*) FROM public.customers) AS b"))
      .to eq([])
  end

  it "keeps a shared conjunct that could raise in each member's FILTER, after the member's own guard" do
    expect_rewrite(
      "SELECT (SELECT count(*) FROM public.orders WHERE amount <> 0 AND 10 / amount > 1) AS a, " \
      "(SELECT count(*) FROM public.orders WHERE status = 'shipped' AND 10 / amount > 1) AS b",
      "SELECT quaack_aggs_1.a_1 AS a, quaack_aggs_1.a_2 AS b FROM (SELECT count(*) FILTER (WHERE amount <> $1 AND " \
      "($2 / amount) > $3) AS a_1, count(*) FILTER (WHERE status = $4 AND ($5 / amount) > $6) AS a_2 " \
      "FROM public.orders) quaack_aggs_1"
    )
  end

  it "refuses what it can't prove" do
    member = "(SELECT count(*) FROM public.orders WHERE status = 'shipped') AS s"
    expect_refusals(
      [
        # A correlated member.
        ["SELECT (SELECT count(*) FROM public.orders WHERE orders.customer_id = c.id) AS a, #{member} " \
         "FROM public.customers c",
         "SELECT (SELECT count(*) FROM public.orders WHERE orders.customer_id = 1) AS a, #{member} " \
         "FROM public.customers c"],
        # A member's own FILTER, GROUP BY, LIMIT, join, and nested subquery.
        ["SELECT (SELECT count(*) FILTER (WHERE amount > 1) FROM public.orders) AS a, #{member}",
         "SELECT (SELECT count(*) FROM public.orders WHERE amount > 1) AS a, #{member}"],
        ["SELECT (SELECT count(*) FROM public.orders GROUP BY status LIMIT 1) AS a, #{member}",
         "SELECT (SELECT count(*) FROM public.orders) AS a, #{member}"],
        ["SELECT (SELECT count(*) FROM public.orders, public.customers) AS a, #{member}",
         "SELECT (SELECT count(*) FROM public.orders) AS a, #{member}"],
        ["SELECT (SELECT count(*) FROM public.orders WHERE customer_id IN (SELECT id FROM public.customers)) AS a, " \
         "#{member}",
         "SELECT (SELECT count(*) FROM public.orders WHERE customer_id IN (1, 2)) AS a, #{member}"],
        # Not an aggregate, which over no rows gives no row, not NULL.
        ["SELECT (SELECT abs(amount) FROM public.orders WHERE id = 99) AS a, " \
         "(SELECT abs(amount) FROM public.orders WHERE id = 99) AS b",
         "SELECT (SELECT max(amount) FROM public.orders WHERE id = 99) AS a, " \
         "(SELECT max(amount) FROM public.orders WHERE id = 99) AS b"],
        # A volatile call.
        ["SELECT (SELECT count(*) FROM public.orders WHERE amount > random()) AS a, #{member}",
         "SELECT (SELECT count(*) FROM public.orders WHERE amount > 0) AS a, #{member}"],
        # An outer bare *, an outer GROUP BY, and an outer aggregate.
        ["SELECT *, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers",
         "SELECT customers.*, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers"],
        ["SELECT customers.name, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers " \
         "GROUP BY customers.name",
         "SELECT customers.name, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers"],
        ["SELECT count(*) AS n, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers",
         "SELECT 1 AS n, (SELECT count(*) FROM public.orders) AS a, #{member} FROM public.customers"],
        # With an outer FROM, which can hold no rows, a member that could raise.
        ["SELECT (SELECT count(*) FROM public.orders WHERE 10 / (amount + 1) > 1) AS a, #{member} " \
         "FROM public.customers",
         "SELECT (SELECT count(*) FROM public.orders WHERE amount > 1) AS a, #{member} FROM public.customers"],
        ["SELECT (SELECT sum(amount + 1) FROM public.orders) AS a, #{member} FROM public.customers",
         "SELECT (SELECT sum(amount) FROM public.orders) AS a, #{member} FROM public.customers"],
        # No outer FROM, but a WHERE.
        ["SELECT (SELECT count(*) FROM public.orders) AS a, #{member} WHERE false",
         "SELECT (SELECT count(*) FROM public.orders) AS a, #{member}"]
      ]
    )
  end
end
