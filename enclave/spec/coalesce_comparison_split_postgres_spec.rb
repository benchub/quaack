# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' coalesce_comparison_split, on a real server:
# what it writes, that its output returns the rows its input does for every
# pair of literals that tells the forms apart, and that it fires only on a
# WHERE or inner-join ON conjunct whose COALESCE has the column's own type.
RSpec.describe Quaack::Enclave::RewriteRules::CoalesceComparisonSplit do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Task 2 has no status, which the UI shows as new. ci is citext, so 'NEW'
  # and 'new' are equal as citext and unequal as text.
  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS citext;
      CREATE TABLE public.tasks (id int PRIMARY KEY, title text, status varchar(20), ci citext, owner_id int);
      INSERT INTO public.tasks VALUES (1, 'a', 'blocked', 'NEW', 1), (2, 'b', NULL, NULL, 1),
                                      (3, 'c', 'new', 'x', 2), (4, 'd', 'done', 'new', NULL);
      CREATE TABLE public.users (id int PRIMARY KEY, name text);
      INSERT INTO public.users VALUES (1, 'ann'), (2, 'bob');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def rewritten(sql) = rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

  def rows(sql, params) = conn.exec_params(sql, params).values.sort_by(&:to_s)

  # Checks that every rewrite returns the original's rows for each set of
  # params, and gives the original's rows for the first.
  def same_rows(sql, rewrites, param_sets)
    expect(rewrites).not_to be_empty
    param_sets.each do |params|
      rewrites.each { expect(rows(it, params)).to eq(rows(sql, params)), "#{it} with #{params}" }
    end
    rows(sql, param_sets.first)
  end

  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  # Every pair of the default and the compared value that tells NULLs apart.
  pairs = [%w[new blocked], %w[new new], %w[blocked blocked], %w[done new]]

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["coalesce_comparison_split",
       "A COALESCE of a column and a placeholder compared with = or <> to a placeholder, in a WHERE or " \
       "inner-join ON, is split into a comparison of the column and a test for its NULLs."]
    )
  end

  it "splits an = into the column's comparison and its NULLs, with nothing to assume" do
    sql = "SELECT t.id FROM public.tasks t WHERE COALESCE(t.status, $1) = $2"
    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT t.id FROM public.tasks t WHERE t.status = $2 OR (t.status IS NULL AND COALESCE($1, t.status) = $2)"]
    )
    expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq([[]])
    expect(same_rows(sql, rewrites, pairs)).to eq([["1"]])
  end

  it "splits a <> the same way" do
    sql = "SELECT t.id FROM public.tasks t WHERE COALESCE(t.status, $1) <> $2"
    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT t.id FROM public.tasks t WHERE t.status <> $2 OR (t.status IS NULL AND COALESCE($1, t.status) <> $2)"]
    )
    expect(same_rows(sql, rewrites, pairs)).to eq([["2"], ["3"], ["4"]])
  end

  it "takes Rails' unaliased form with the COALESCE on the right, other conjuncts, and a cast to the column's type" do
    sql = qualified('SELECT "tasks".* FROM "tasks" WHERE "tasks"."owner_id" = $1 AND ' \
                    '$2 = COALESCE("tasks"."status", $3::varchar(20)) ORDER BY "tasks"."id" LIMIT $4')
    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT tasks.* FROM public.tasks WHERE tasks.owner_id = $1 AND ($2 = tasks.status OR " \
       "(tasks.status IS NULL AND $2 = COALESCE($3::varchar(20), tasks.status))) ORDER BY tasks.id LIMIT $4"]
    )
    params = pairs.map { [1, it.last, it.first, 10] }
    expect(same_rows(sql, rewrites, params)).to eq([%w[1 a blocked NEW 1]])
  end

  it "takes a bare column when the FROM is one table that has it" do
    sql = "SELECT id FROM public.tasks WHERE COALESCE(status, $1) = $2"

    expect(rewritten(sql)).to eq(
      ["SELECT id FROM public.tasks WHERE status = $2 OR (status IS NULL AND COALESCE($1, status) = $2)"]
    )
  end

  it "keeps the column's own operator, as citext's case-blind =" do
    sql = "SELECT t.id FROM public.tasks t WHERE COALESCE(t.ci, $1) = $2"

    expect(same_rows(sql, rewritten(sql), [%w[NEW new], %w[x NEW], %w[y z]])).to eq([["1"], ["2"], ["4"]])
  end

  it "takes an inner join's ON and a subquery's WHERE, one rewrite each" do
    sql = "SELECT u.name FROM public.users u JOIN public.tasks t " \
          "ON t.owner_id = u.id AND COALESCE(t.status, $1) = $2 " \
          "WHERE u.id IN (SELECT s.owner_id FROM public.tasks s WHERE COALESCE(s.status, $3) = $4)"
    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT u.name FROM public.users u JOIN public.tasks t ON t.owner_id = u.id AND (t.status = $2 OR " \
       "(t.status IS NULL AND COALESCE($1, t.status) = $2)) WHERE u.id IN (SELECT s.owner_id FROM public.tasks s " \
       "WHERE COALESCE(s.status, $3) = $4)",
       "SELECT u.name FROM public.users u JOIN public.tasks t ON t.owner_id = u.id AND COALESCE(t.status, $1) = $2 " \
       "WHERE u.id IN (SELECT s.owner_id FROM public.tasks s WHERE s.status = $4 OR (s.status IS NULL AND " \
       "COALESCE($3, s.status) = $4))"]
    )
    expect(same_rows(sql, rewrites, pairs.map { it + it })).to eq([["ann"]])
  end

  it "doesn't change the parse it was given" do
    parse = PgQuery.parse("SELECT t.id FROM public.tasks t WHERE COALESCE(t.status, $1) = $2")
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog).size).to eq(1)
    expect(parse.tree).to eq(before)
  end

  {
    "under a NOT, where NULL and false differ" => "WHERE NOT (COALESCE(t.status, $1) = $2)",
    "in an OR" => "WHERE COALESCE(t.status, $1) = $2 OR t.id = 1",
    "under an IS NULL" => "WHERE t.id > 0 AND (COALESCE(t.status, $1) = $2) IS NULL",
    "in a LEFT JOIN's ON" => "LEFT JOIN public.users u ON COALESCE(t.status, $1) = $2",
    "the default is a cast to another type" => "WHERE COALESCE(t.status, $1::text) = $2",
    "the default isn't a placeholder" => "WHERE COALESCE(t.status, t.title) = $2",
    "the compared value isn't a placeholder" => "WHERE COALESCE(t.status, $1) = t.title",
    "COALESCE has three arguments" => "WHERE COALESCE(t.status, $1, $3) = $2",
    "the operator is <" => "WHERE COALESCE(t.status, $1) < $2",
    "the operator is IS NOT DISTINCT FROM, which is true for NULLs" =>
      "WHERE COALESCE(t.status, $1) IS NOT DISTINCT FROM $2",
    "the operator is = ANY" => "WHERE COALESCE(t.status, $1) = ANY($2)",
    "the operator is schema-qualified" => "WHERE COALESCE(t.status, $1) OPERATOR(pg_catalog.=) $2",
    "the column's table isn't in this FROM" => "WHERE COALESCE(x.status, $1) = $2",
    "the default placeholder is used elsewhere, which may give it another type" =>
      "WHERE COALESCE(t.status, $1) = $2 AND t.owner_id = $1"
  }.each do |why, tail|
    it "doesn't fire when #{why}" do
      expect(rewritten("SELECT t.id FROM public.tasks t #{tail}")).to eq([])
    end
  end

  it "doesn't fire on a table with column aliases, which rename its columns" do
    expect(rewritten("SELECT t.a FROM public.tasks t (a, b, status) WHERE COALESCE(t.status, $1) = $2")).to eq([])
  end

  it "doesn't fire on a bare column when the FROM has two tables" do
    sql = "SELECT t.id FROM public.tasks t, public.users u WHERE COALESCE(status, $1) = $2"

    expect(rewritten(sql)).to eq([])
  end
end
