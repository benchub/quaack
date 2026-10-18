# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/aggregate_before_join"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' aggregate_before_join, on a real server: a
# GROUP BY of one table's key over its join to another aggregates the other
# table first, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::AggregateBeforeJoin do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # A user with no orders, a user the user filter drops but who has paid
  # orders, orders with no user and with a user that doesn't exist, and
  # refunded orders, so a rewrite that kept a user with nothing to count,
  # lost the filter, or counted the wrong rows would show.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, name text NOT NULL, team int);
      CREATE TABLE public.orders (id int PRIMARY KEY, user_id int, big_user_id bigint, total int NOT NULL,
                                  status text NOT NULL);
      CREATE TABLE public.notes (user_id int, body text);
      INSERT INTO public.users VALUES (1, 'ann', 1), (2, 'bob', 1), (3, 'cy', 2), (4, 'dee', NULL);
      INSERT INTO public.orders VALUES
        (1, 1, 1, 10, 'paid'), (2, 1, 1, 20, 'paid'), (3, 1, 1, 5, 'refunded'), (4, 2, 2, 7, 'paid'),
        (5, 3, 3, 9, 'paid'), (6, 3, 3, 1, 'paid'), (7, NULL, NULL, 3, 'paid'), (8, 9, 9, 4, 'paid'),
        (9, 4, 4, 2, 'refunded');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def generated(sql) = rule.rewrites(PgQuery.parse(redacted(sql).sql), catalog)

  def rewritten(sql) = generated(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

  def rows(sql, map, ordered: false)
    name = "quaack_rule_spec"
    result = Quaack::Enclave::Redaction.binding(sql, map).tap { it.prepare(conn, name) }.execute(conn, name)
    [result.fields, ordered ? result.values : result.values.sort_by(&:to_s)]
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  # sql's rows and column names are rewrite's.
  def expect_same_rows(sql, rewrite, ordered: false)
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map, ordered:)
    expect(want.last).not_to be_empty
    expect(rows(rewrite, original.placeholder_map, ordered:)).to eq(want)
  end

  def expect_rewrite(sql, expected, ordered: false)
    expect(rewritten(sql)).to eq([expected])
    expect_same_rows(sql, expected, ordered:)
  end

  # For each [refused, fires] pair, the rule leaves refused alone and
  # rewrites fires, its positive twin. Both run on the server.
  def expect_refusals(pairs)
    pairs.each do |refused, fires|
      conn.exec(refused)
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(fires).size).to eq(1), fires
    end
  end

  let(:users_key) do
    [{ "kind" => "unique", "table" => "public.users", "columns" => ["id"] },
     { "kind" => "not_null", "table" => "public.users", "column" => "id" }]
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["aggregate_before_join",
       "A GROUP BY of a unique, not-null key of one table, over its inner join to another table whose rows it " \
       "aggregates, aggregates that table first, by its join columns, and joins the result."]
    )
  end

  it "aggregates Rails' joins(:orders).group(\"users.id\").count first, moving the orders filter and keeping " \
     "the users filter" do
    sql = "SELECT COUNT(*) AS count_all, users.id AS users_id FROM public.users " \
          "INNER JOIN public.orders ON orders.user_id = users.id " \
          "WHERE orders.status = 'paid' AND users.name <> 'cy' GROUP BY users.id"

    expect_rewrite(sql, "SELECT quaack_pre_1.a_1 AS count_all, users.id AS users_id FROM public.users " \
                        "JOIN (SELECT orders.user_id, count(*) AS a_1 FROM public.orders WHERE orders.status = $1 " \
                        "GROUP BY orders.user_id) quaack_pre_1 ON quaack_pre_1.user_id = users.id " \
                        "WHERE users.name <> $2")
    expect(generated(sql).map(&:assumptions)).to eq([users_key])
    expect(rows(redacted(sql).sql, redacted(sql).placeholder_map).last).to eq([%w[1 2], %w[2 1]])
  end

  it "takes a comma join, the joined table first, several aggregates with their default names, and a HAVING" do
    expect_rewrite(
      "SELECT u.id, u.name, sum(o.total), max(o.status) AS last_status FROM public.orders o, public.users u " \
      "WHERE o.user_id = u.id GROUP BY u.id, u.name HAVING count(*) > 1",
      "SELECT u.id, u.name, quaack_pre_1.a_1 AS sum, quaack_pre_1.a_2 AS last_status FROM " \
      "(SELECT o.user_id, sum(o.total) AS a_1, max(o.status) AS a_2 FROM public.orders o GROUP BY o.user_id " \
      "HAVING count(*) > $1) quaack_pre_1 JOIN public.users u ON quaack_pre_1.user_id = u.id"
    )
  end

  it "keeps ORDER BY a column of the key's table, an output name, and an ordinal, with LIMIT and OFFSET" do
    expect_rewrite(
      "SELECT users.id, users.name, count(*) AS n FROM public.users JOIN public.orders " \
      "ON users.id = orders.user_id GROUP BY users.id ORDER BY n DESC, users.name, 1 LIMIT 3 OFFSET 0",
      "SELECT users.id, users.name, quaack_pre_1.a_1 AS n FROM public.users JOIN (SELECT orders.user_id, " \
      "count(*) AS a_1 FROM public.orders GROUP BY orders.user_id) quaack_pre_1 ON users.id = " \
      "quaack_pre_1.user_id ORDER BY n DESC, users.name, 1 LIMIT $1 OFFSET $2", ordered: true
    )
  end

  it "refuses what it can't rewrite, and rewrites each one's twin" do
    join = "FROM public.users u JOIN public.orders o ON o.user_id = u.id"
    fires = "SELECT u.id, count(*) AS n #{join} GROUP BY u.id"
    expect_refusals(
      [["SELECT u.id, count(*) AS n FROM public.users u LEFT JOIN public.orders o ON o.user_id = u.id GROUP BY u.id",
        fires],
       ["SELECT DISTINCT u.id, count(*) AS n #{join} GROUP BY u.id", fires],
       ["SELECT u.id, count(*) AS n, rank() OVER () #{join} GROUP BY u.id", fires],
       ["SELECT u.id, count(*) AS n #{join} WHERE random() < 2 GROUP BY u.id",
        "SELECT u.id, count(*) AS n #{join} WHERE u.team < 2 GROUP BY u.id"],
       ["SELECT u.*, count(*) AS n #{join} GROUP BY u.id", fires],
       ["SELECT u.name, count(*) AS n #{join} GROUP BY u.name", fires],
       ["SELECT u.id, o.status, count(*) AS n #{join} GROUP BY u.id, o.status", fires],
       ["SELECT u.id, sum(u.team) AS n #{join} GROUP BY u.id", "SELECT u.id, sum(o.total) AS n #{join} GROUP BY u.id"],
       ["SELECT u.id, count(*) AS n #{join} AND o.total > u.team GROUP BY u.id",
        "SELECT u.id, count(*) AS n #{join} AND o.total > 1 GROUP BY u.id"],
       ["#{fires} HAVING u.id > 0", "#{fires} HAVING count(*) > 0"],
       ["SELECT u.id, count(*) AS n #{join} JOIN public.notes x ON x.user_id = u.id GROUP BY u.id", fires],
       ["SELECT u.id, count(*) AS n #{join} WHERE o.total / o.id > 1 GROUP BY u.id",
        "SELECT u.id, count(*) AS n #{join} WHERE o.total > 1 GROUP BY u.id"],
       ["SELECT u.id, sum(o.total / o.id) AS n #{join} GROUP BY u.id",
        "SELECT u.id, sum(o.total) AS n #{join} GROUP BY u.id"],
       ["SELECT u.id, count(*) AS n FROM public.users u JOIN public.orders o ON o.big_user_id = u.id GROUP BY u.id",
        fires],
       ["SELECT u.id, count(*) AS n #{join} WHERE total > 1 GROUP BY u.id",
        "SELECT u.id, count(*) AS n #{join} WHERE o.total > 1 GROUP BY u.id"],
       ["SELECT u.id, count(*) AS n #{join} WHERE u.id IN (SELECT 1) GROUP BY u.id", fires],
       ["#{fires} ORDER BY count(*)", "#{fires} ORDER BY n"],
       ["#{fires} ORDER BY max(u.team)", "#{fires} ORDER BY u.team"],
       ["SELECT u.id + 1 AS k, count(*) AS n #{join} GROUP BY u.id", fires],
       ["SELECT x.user_id, count(*) AS n FROM public.notes x JOIN public.orders o ON o.user_id = x.user_id " \
        "GROUP BY x.user_id", fires],
       ["SELECT u.id, count(*) AS n FROM public.users u JOIN public.orders o ON o.user_id = u.id OR o.id = u.id " \
        "GROUP BY u.id", fires],
       ["#{fires} UNION SELECT 1, 1", fires]]
    )
  end
end
