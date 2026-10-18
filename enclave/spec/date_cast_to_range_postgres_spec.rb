# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' date_cast_to_range, on a real server: what it
# writes, that its output returns the rows its input does on rows on each
# side of midnight, in a time zone with a DST change, that it asks the
# literal oracle that each day is a finite date, and that it fires only on
# a cast it can turn into a range.
RSpec.describe Quaack::Enclave::RewriteRules::DateCastToRange do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # The session runs in New York, where 2025-03-09 has 23 hours. Each
  # order's at and local are the same local time, the one a timestamptz
  # and the other a timestamp: the last second of 03-08, midnight and the
  # last second of 03-09, midnight of 03-10, and 03-11 noon. Order 6 has no
  # time, and 7 is infinitely late.
  before do
    conn.exec(<<~SQL)
      SET TimeZone = 'America/New_York';
      CREATE TABLE public.customers (id int PRIMARY KEY, name text NOT NULL);
      CREATE TABLE public.orders (id int PRIMARY KEY, customer_id int, at timestamptz, local timestamp,
                                  day date, label text);
      INSERT INTO public.customers VALUES (1, 'a'), (2, 'b');
      INSERT INTO public.orders (id, customer_id, local) VALUES
        (1, 1, '2025-03-08 23:59:59'), (2, 1, '2025-03-09 00:00:00'), (3, 2, '2025-03-09 23:59:59'),
        (4, 2, '2025-03-10 00:00:00'), (5, 1, '2025-03-11 12:00:00'), (6, 2, NULL), (7, 1, 'infinity');
      UPDATE public.orders SET at = local::timestamptz, day = local::date, label = local::date::text;
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def literals_for(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    [redacted, Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)]
  end

  def rewritten(sql)
    redacted, literals = literals_for(sql)
    rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, map)
    name = "quaack_date_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    binding.execute(conn, name).values
  ensure
    conn.exec("DEALLOCATE ALL")
  end

  # The original's ids, once the rewrite has been checked to return the
  # same ones, bound with the original's literals.
  def same_ids(sql, rewrite)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    expected = rows(redacted.sql, redacted.placeholder_map).flatten.sort_by(&:to_i)
    expect(rows(rewrite, redacted.placeholder_map).flatten.sort_by(&:to_i)).to eq(expected)
    expected
  end

  def orders(test) = "SELECT o.id FROM public.orders o WHERE o.customer_id > 0 AND #{test}"

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["date_cast_to_range",
       "A timestamp column cast to date and compared with a date becomes a range on the column."]
    )
  end

  it "makes a timestamptz cast to date and compared with a day a half-open range, with nothing to rely on" do
    sql = orders("o.at::date = '2025-03-09'")
    redacted, literals = literals_for(sql)
    found = rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals)

    expect(found.map(&:assumptions)).to eq([[]])
    rewrite = Quaack::Enclave::Deparse.faithfully(found.first.tree)
    expect(rewrite).to eq("SELECT o.id FROM public.orders o WHERE o.customer_id > $1 AND " \
                          "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)")
    expect(same_ids(sql, rewrite)).to eq(%w[2 3])
  end

  range = "SELECT o.id FROM public.orders o WHERE o.customer_id > $1 AND "
  {
    "o.at::date >= '2025-03-09'" => ["o.at >= $2::pg_catalog.date", %w[2 3 4 5 7]],
    "o.at::date > '2025-03-09'" => ["o.at >= ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4 5 7]],
    "o.at::date < '2025-03-09'" => ["o.at < $2::pg_catalog.date", %w[1]],
    "o.at::date <= '2025-03-09'" => ["o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[1 2 3]],
    "'2025-03-09' < o.at::date" => ["o.at >= ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4 5 7]],
    "'2025-03-09' >= o.at::date" => ["o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[1 2 3]],
    "'2025-03-09' = o.at::date" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[2 3]
    ],
    "o.at::date OPERATOR(pg_catalog.=) '2025-03-09'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[2 3]
    ],
    "o.at::date BETWEEN '2025-03-09' AND '2025-03-10'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($3::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[2 3 4]
    ],
    "CAST(o.at AS date) = '2025-03-10'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4]
    ],
    "date(o.at) = '2025-03-10'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4]
    ],
    "pg_catalog.date(o.at) = '2025-03-10'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4]
    ],
    "o.at::pg_catalog.date = '2025-03-10'" => [
      "o.at >= $2::pg_catalog.date AND o.at < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4]
    ],
    "o.at::date = '2025-03-10'::date" => ["o.at >= $2::date AND o.at < ($2::date OPERATOR(pg_catalog.+) 1)", %w[4]],
    "o.at::date = DATE '2025-03-10'" => ["o.at >= $2::date AND o.at < ($2::date OPERATOR(pg_catalog.+) 1)", %w[4]],
    "o.local::date = '2025-03-09'" => [
      "o.local >= $2::pg_catalog.date AND o.local < ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[2 3]
    ],
    "o.local::date > '2025-03-09'" => ["o.local >= ($2::pg_catalog.date OPERATOR(pg_catalog.+) 1)", %w[4 5 7]]
  }.each do |test, (expected, ids)|
    it "rewrites #{test}" do
      rewrite = rewritten(orders(test))

      expect(rewrite).to eq(["#{range}#{expected}"])
      expect(same_ids(orders(test), rewrite.first)).to eq(ids)
    end
  end

  it "takes a bare column and an ORM's quoted names" do
    sql = 'SELECT "orders"."id" FROM "public"."orders" WHERE ("orders"."at"::date = \'2025-03-09\')'
    bare = "SELECT id FROM public.orders WHERE at::date = '2025-03-09'"

    expect(rewritten(sql)).to eq(["SELECT orders.id FROM public.orders WHERE orders.at >= $1::pg_catalog.date AND " \
                                  "orders.at < ($1::pg_catalog.date OPERATOR(pg_catalog.+) 1)"])
    expect(rewritten(bare)).to eq(["SELECT id FROM public.orders WHERE at >= $1::pg_catalog.date AND " \
                                   "at < ($1::pg_catalog.date OPERATOR(pg_catalog.+) 1)"])
    expect(same_ids(bare, rewritten(bare).first)).to eq(%w[2 3])
  end

  it "rewrites an inner join's ON, a subquery's WHERE, and every match at once" do
    sql = "SELECT c.id FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
          "AND o.at::date = '2025-03-09' WHERE c.id IN (SELECT p.customer_id FROM public.orders p " \
          "WHERE p.local::date >= '2025-03-11')"
    rewrite = rewritten(sql)

    expect(rewrite).to eq(["SELECT c.id FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
                           "AND o.at >= $1::pg_catalog.date " \
                           "AND o.at <($1::pg_catalog.date OPERATOR(pg_catalog.+) 1) " \
                           "WHERE c.id IN (SELECT p.customer_id " \
                           "FROM public.orders p WHERE p.local >= $2::pg_catalog.date)"])
    expect(same_ids(sql, rewrite.first)).to eq(%w[1])
  end

  {
    "a date column" => "o.day::date = '2025-03-09'",
    "a text column" => "o.label::date = '2025-03-09'",
    "a timestamp the day is compared as" => "o.at::date = '2025-03-09 12:00'::timestamp",
    "a typed timestamp" => "o.at::date = TIMESTAMP '2025-03-09 12:00'",
    "an infinite day" => "o.at::date = 'infinity'",
    "an infinite day, cast" => "o.at::date >= '-infinity'::date",
    "the last date" => "o.at::date = '5874897-12-31'",
    "a day after the last timestamp" => "o.at::date < '294277-01-01'",
    "a day whose next isn't a timestamp" => "o.at::date <= '294276-12-31'",
    "a number, which fails as it is" => "o.at::date = 20250309",
    "a NULL" => "o.at::date = NULL",
    "<>" => "o.at::date <> '2025-03-09'",
    "NOT BETWEEN" => "o.at::date NOT BETWEEN '2025-03-09' AND '2025-03-10'",
    "BETWEEN SYMMETRIC" => "o.at::date BETWEEN SYMMETRIC '2025-03-10' AND '2025-03-09'",
    "BETWEEN with one bound not a day" => "o.at::date BETWEEN '2025-03-09' AND 'infinity'",
    "an OR" => "(o.at::date = '2025-03-09' OR o.id = 1)",
    "a NOT" => "NOT (o.at::date = '2025-03-09')",
    "an expression for the day" => "o.at::date = '2025-03-09'::date + 1",
    "a cast to timestamp(0)" => "o.at::timestamp(0) = '2025-03-09'",
    "an expression for the column" => "(o.at + interval '1 hour')::date = '2025-03-09'",
    "a column of a subquery" => "o.id IN (SELECT 1 FROM public.customers c WHERE o.at::date = '2025-03-09')",
    "another function named date" => "public.date(o.at) = '2025-03-09'"
  }.each do |what, test|
    it "leaves #{what} alone" do
      conn.exec("CREATE FUNCTION public.date(timestamptz) RETURNS date LANGUAGE sql AS 'SELECT DATE ''2025-03-09'''")
      expect(rewritten(orders(test))).to eq([])
    end
  end

  it "leaves a left join's ON alone" do
    sql = "SELECT c.id FROM public.customers c LEFT JOIN public.orders o ON o.customer_id = c.id " \
          "AND o.at::date = '2025-03-09'"
    expect(rewritten(sql)).to eq([])
  end

  it "does nothing with no literal oracle" do
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(orders("o.at::date = '2025-03-09'")))
    expect(rule.rewrites(PgQuery.parse(redacted.sql), catalog)).to eq([])
  end
end
