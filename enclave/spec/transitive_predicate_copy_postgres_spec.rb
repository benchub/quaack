# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/transitive_predicate_copy"
require_relative "support/production_server"

# DESIGN.md 6c's transitive_predicate_copy, on a real server: a filter on
# one side of a column equality is copied to the other side, in the same
# place, reusing its placeholders, and every rewrite returns the original's
# rows.
RSpec.describe Quaack::Enclave::RewriteRules::TransitivePredicateCopy do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.enrollments (
        id int PRIMARY KEY, course_id int, big bigint, code varchar(20), created_at date,
        name text, name_c text COLLATE "C", loose text COLLATE public.loose
      );
      CREATE TABLE public.assessor_asset (
        id int PRIMARY KEY, course_id int, code varchar(20), created_at date, name text,
        loose text COLLATE public.loose
      );
      CREATE TABLE public.courses (id int PRIMARY KEY, account_id int);
      INSERT INTO public.enrollments VALUES
        (1, 1, 1, 'a', '2019-06-01', 'a', 'a', 'a'),
        (2, 2, 2, 'b', '2020-06-01', 'b', 'b', 'B'),
        (3, 3, 3, 'c', '2020-09-01', 'c', 'c', 'c'),
        (4, 4, 4, 'd', '2021-06-01', 'd', 'd', 'd'),
        (5, 2, 2, 'e', '2020-03-01', 'e', 'e', 'e'),
        (6, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
      INSERT INTO public.assessor_asset VALUES
        (1, 1, 'a', '2019-06-01', 'a', 'a'),
        (2, 2, 'b', '2020-06-01', 'b', 'b'),
        (3, 3, 'c', '2020-09-01', 'c', 'c'),
        (4, 3, 'd', '2021-06-01', 'd', 'd'),
        (5, 5, 'e', '2020-03-01', 'e', 'e'),
        (6, NULL, NULL, NULL, NULL, NULL);
      INSERT INTO public.courses VALUES (1, 1), (2, 1), (3, 2), (4, 2), (5, 3);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  def literals_for(sql)
    redacted = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)
    [redacted.sql, literals]
  end

  def rewritten(sql)
    redacted, literals = literals_for(sql)
    rule.rewrites(PgQuery.parse(redacted), catalog, literals).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, map)
    name = "quaack_rule_spec"
    binding = Quaack::Enclave::Redaction.binding(sql, map)
    binding.prepare(conn, name)
    binding.execute(conn, name).values.sort_by(&:to_s)
  ensure
    begin
      conn.exec("DEALLOCATE #{name}")
    rescue StandardError
      nil
    end
  end

  # The rewrite of sql is exactly expected, and returns sql's rows, which
  # aren't empty.
  def expect_rewrite(sql, expected)
    expect(rewritten(sql)).to eq([expected])
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map)
    expect(want).not_to be_empty
    expect(rows(expected, original.placeholder_map)).to eq(want)
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["transitive_predicate_copy",
       "A filter on one side of a column equality in a WHERE or inner-join ON is copied to the other side."]
    )
  end

  it "copies a WHERE IN list across an inner join's equality into the WHERE" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id WHERE assessor_asset.course_id IN (2, 3)",
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id " \
      "WHERE assessor_asset.course_id IN ($1, $2) AND enrollments.course_id IN ($1, $2)"
    )
  end

  it "copies comparisons with a constant, either way round, and BETWEEN, on int, date, and varchar" do
    expect_rewrite(
      "SELECT enrollments.id, assessor_asset.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND enrollments.created_at = assessor_asset.created_at AND " \
      "assessor_asset.code = enrollments.code AND enrollments.course_id >= 2 AND 4 > enrollments.course_id AND " \
      "assessor_asset.created_at > '2020-01-01' AND assessor_asset.created_at <= '2021-01-01' AND " \
      "assessor_asset.code BETWEEN 'b' AND 'd'",
      "SELECT enrollments.id, assessor_asset.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND enrollments.created_at = assessor_asset.created_at AND " \
      "assessor_asset.code = enrollments.code AND enrollments.course_id >= $1 AND $2 > enrollments.course_id AND " \
      "assessor_asset.created_at > $3 AND assessor_asset.created_at <= $4 AND " \
      "assessor_asset.code BETWEEN $5 AND $6 AND assessor_asset.course_id >= $1 AND " \
      "$2 > assessor_asset.course_id AND " \
      "enrollments.created_at > $3 AND enrollments.created_at <= $4 AND enrollments.code BETWEEN $5 AND $6"
    )
  end

  it "puts the copy of an inner join's ON conjunct in that ON, not the WHERE" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON assessor_asset.id = enrollments.id AND assessor_asset.course_id IN (2, 3) " \
      "WHERE enrollments.course_id = assessor_asset.course_id",
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON assessor_asset.id = enrollments.id AND assessor_asset.course_id IN ($1, $2) " \
      "AND enrollments.course_id IN ($1, $2) WHERE enrollments.course_id = assessor_asset.course_id"
    )
  end

  it "copies into an ON and into the WHERE in one call" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id >= 2 " \
      "WHERE assessor_asset.course_id <= 3",
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id >= $1 " \
      "AND enrollments.course_id >= $1 WHERE assessor_asset.course_id <= $2 AND enrollments.course_id <= $2"
    )
  end

  it "doesn't copy into an ON a column of a table joined after it" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments " \
      "JOIN public.courses ON courses.id = enrollments.course_id AND enrollments.course_id IN (2, 3) " \
      "JOIN public.assessor_asset ON assessor_asset.course_id = courses.id",
      "SELECT enrollments.id FROM public.enrollments " \
      "JOIN public.courses ON courses.id = enrollments.course_id AND enrollments.course_id IN ($1, $2) " \
      "AND courses.id IN ($1, $2) JOIN public.assessor_asset ON assessor_asset.course_id = courses.id"
    )
  end

  it "carries a filter along a chain of equalities in one call" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset, public.courses WHERE " \
      "courses.id IN (2, 3) AND enrollments.course_id = assessor_asset.course_id AND " \
      "assessor_asset.course_id = courses.id",
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset, public.courses WHERE " \
      "courses.id IN ($1, $2) AND enrollments.course_id = assessor_asset.course_id AND " \
      "assessor_asset.course_id = courses.id AND assessor_asset.course_id IN ($1, $2) AND " \
      "enrollments.course_id IN ($1, $2)"
    )
  end

  it "stops when equalities form a cycle" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id = enrollments.course_id AND " \
      "enrollments.course_id IN (2, 3)",
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id = enrollments.course_id AND " \
      "enrollments.course_id IN ($1, $2) AND assessor_asset.course_id IN ($1, $2)"
    )
  end

  it "doesn't add a copy that's already there, in the WHERE or an ON, with other placeholders for the same literals" do
    expect(rewritten(
             "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
             "ON enrollments.course_id = assessor_asset.course_id AND enrollments.course_id IN (2, 3) " \
             "WHERE assessor_asset.course_id IN (2, 3)"
           )).to eq([])
  end

  it "adds a copy when the conjunct already there has different literals" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND enrollments.course_id IN (2, 4) AND " \
      "assessor_asset.course_id IN (2, 3)",
      "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
      "enrollments.course_id = assessor_asset.course_id AND enrollments.course_id IN ($1, $2) AND " \
      "assessor_asset.course_id IN ($3, $4) AND assessor_asset.course_id IN ($1, $2) AND " \
      "enrollments.course_id IN ($3, $4)"
    )
  end

  it "copies only IN lists, ranges, and BETWEEN of plain constants", :aggregate_failures do
    [
      "assessor_asset.course_id IS NOT NULL",
      "assessor_asset.course_id NOT IN (2, 3)",
      "assessor_asset.course_id <> 2",
      "assessor_asset.course_id = 2",
      "assessor_asset.course_id NOT BETWEEN 2 AND 3",
      "assessor_asset.code LIKE 'b%'",
      "assessor_asset.course_id > assessor_asset.id",
      "assessor_asset.course_id IN (2, (random() * 10)::int)",
      "assessor_asset.course_id > random()",
      "assessor_asset.course_id IN (2::int, 3)",
      "assessor_asset.course_id > 2::bigint",
      "assessor_asset.course_id BETWEEN 2 AND 3::int",
      "assessor_asset.created_at > '2020-01-01'::date",
      "assessor_asset.created_at > CAST('2020-01-01' AS date)",
      "assessor_asset.code >= 'b' COLLATE \"C\""
    ].each do |filter|
      sql = "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
            "enrollments.course_id = assessor_asset.course_id AND enrollments.code = assessor_asset.code AND " \
            "enrollments.created_at = assessor_asset.created_at AND #{filter}"

      expect(rewritten(sql)).to eq([]), filter
    end
  end

  it "refuses columns of different types or collations, or a comparison that isn't =", :aggregate_failures do
    {
      "enrollments.big = assessor_asset.course_id" => "assessor_asset.course_id IN (2, 3)",
      "enrollments.name_c = assessor_asset.name" => "assessor_asset.name >= 'b'",
      "enrollments.course_id <= assessor_asset.course_id" => "assessor_asset.course_id IN (2, 3)"
    }.each do |equality, filter|
      sql = "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE #{equality} AND #{filter}"

      expect(rewritten(sql)).to eq([]), equality
    end
  end

  it "refuses a column with a nondeterministic collation" do
    sql = "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
          "enrollments.loose = assessor_asset.loose AND assessor_asset.loose >= 'b'"

    expect(rewritten(sql)).to eq([])
  end

  it "refuses an equality that isn't the type's default btree equality" do
    conn.exec(<<~SQL)
      CREATE FUNCTION public.loose_eq(varchar, varchar) RETURNS boolean
        LANGUAGE sql IMMUTABLE AS 'SELECT lower($1) = lower($2)';
      CREATE OPERATOR public.= (LEFTARG = varchar, RIGHTARG = varchar, FUNCTION = public.loose_eq);
      UPDATE public.assessor_asset SET code = upper(code);
    SQL
    sql = "SELECT enrollments.id FROM public.enrollments, public.assessor_asset WHERE " \
          "enrollments.code = assessor_asset.code AND enrollments.code >= 'b'"

    expect(rewritten(sql)).to eq([])
  end

  it "refuses a column whose type has no default btree, such as a domain with its own =" do
    conn.exec(<<~SQL)
      CREATE DOMAIN public.digit AS int;
      CREATE FUNCTION public.digit_eq(public.digit, public.digit) RETURNS boolean
        LANGUAGE sql IMMUTABLE AS 'SELECT $1 % 10 = $2 % 10';
      CREATE OPERATOR public.= (LEFTARG = public.digit, RIGHTARG = public.digit, FUNCTION = public.digit_eq);
      CREATE TABLE public.left_digits (id int, d public.digit);
      CREATE TABLE public.right_digits (id int, d public.digit);
      INSERT INTO public.left_digits VALUES (1, 3);
      INSERT INTO public.right_digits VALUES (1, 13);
    SQL
    sql = "SELECT left_digits.id FROM public.left_digits, public.right_digits WHERE " \
          "left_digits.d = right_digits.d AND left_digits.d <= 3"

    expect(conn.exec(sql).values).to eq([["1"]])
    expect(rewritten(sql)).to eq([])
  end

  it "never uses or copies to a column on an outer join's nullable side", :aggregate_failures do
    [
      "SELECT enrollments.id FROM public.enrollments LEFT JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id WHERE enrollments.course_id IN (2, 3)",
      "SELECT enrollments.id FROM public.enrollments LEFT JOIN public.assessor_asset " \
      "ON enrollments.id = assessor_asset.id WHERE enrollments.course_id = assessor_asset.course_id " \
      "AND enrollments.course_id IN (2, 3)",
      "SELECT courses.id FROM public.courses LEFT JOIN (public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id IN (2, 3)) " \
      "ON courses.id = enrollments.course_id",
      "SELECT enrollments.id FROM public.enrollments FULL JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id AND assessor_asset.course_id IN (2, 3)",
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON assessor_asset.id = enrollments.id " \
      "LEFT JOIN public.courses ON enrollments.course_id = assessor_asset.course_id " \
      "AND assessor_asset.course_id IN (2, 3)"
    ].each do |sql|
      expect(rewritten(sql)).to eq([]), sql
    end
  end

  it "copies between tables that aren't on an outer join's nullable side when the query has one" do
    expect_rewrite(
      "SELECT enrollments.id, courses.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id LEFT JOIN public.courses " \
      "ON courses.id = enrollments.id WHERE assessor_asset.course_id IN (2, 3)",
      "SELECT enrollments.id, courses.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id LEFT JOIN public.courses " \
      "ON courses.id = enrollments.id WHERE assessor_asset.course_id IN ($1, $2) AND enrollments.course_id IN ($1, $2)"
    )
  end

  it "copies inside a subquery" do
    expect_rewrite(
      "SELECT courses.id FROM public.courses WHERE courses.id IN (SELECT enrollments.course_id " \
      "FROM public.enrollments JOIN public.assessor_asset ON enrollments.course_id = assessor_asset.course_id " \
      "WHERE assessor_asset.course_id IN (2, 3))",
      "SELECT courses.id FROM public.courses WHERE courses.id IN (SELECT enrollments.course_id " \
      "FROM public.enrollments JOIN public.assessor_asset ON enrollments.course_id = assessor_asset.course_id " \
      "WHERE assessor_asset.course_id IN ($1, $2) AND enrollments.course_id IN ($1, $2))"
    )
  end

  it "copies in a SELECT and in a subquery in its WHERE" do
    expect_rewrite(
      "SELECT enrollments.id FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "WHERE courses.id IN (2, 3) AND enrollments.id IN (SELECT enrollments.id FROM public.enrollments " \
      "JOIN public.assessor_asset ON enrollments.course_id = assessor_asset.course_id " \
      "WHERE assessor_asset.course_id >= 2)",
      "SELECT enrollments.id FROM public.enrollments JOIN public.courses ON courses.id = enrollments.course_id " \
      "WHERE courses.id IN ($1, $2) AND enrollments.id IN (SELECT enrollments.id FROM public.enrollments " \
      "JOIN public.assessor_asset ON enrollments.course_id = assessor_asset.course_id " \
      "WHERE assessor_asset.course_id >= $3 AND enrollments.course_id >= $3) AND enrollments.course_id IN ($1, $2)"
    )
  end

  it "doesn't use an equality with a column of an outer query" do
    sql = "SELECT courses.id FROM public.courses WHERE EXISTS (SELECT 1 FROM public.enrollments " \
          "WHERE enrollments.course_id = courses.id AND courses.id IN (2, 3))"

    expect(rewritten(sql)).to eq([])
  end

  it "makes no rewrite without the literals oracle" do
    redacted, = literals_for(
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id WHERE assessor_asset.course_id IN (2, 3)"
    )

    expect(rule.rewrites(PgQuery.parse(redacted), catalog, nil)).to eq([])
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(
      "SELECT enrollments.id FROM public.enrollments JOIN public.assessor_asset " \
      "ON enrollments.course_id = assessor_asset.course_id WHERE assessor_asset.course_id IN (2, 3)"
    )
    parse = PgQuery.parse(redacted)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)
    expect(parse.tree).to eq(before)
  end
end
