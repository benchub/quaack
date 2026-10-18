# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/assumption_check"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' distinct_key_removal, on a real server: what it
# writes, that its output returns the rows its input does on data where a
# DISTINCT that removed anything would show, and that it fires only when the
# catalog proves a selected key of the first table unique and not null and
# every join matches at most one row by a unique key of the joined table.
RSpec.describe Quaack::Enclave::RewriteRules::DistinctKeyRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Posts 10, 11, and 13 share a title, and users 1 and 3 a name, so a
  # DISTINCT over those columns alone merges rows. User 1 is in two orgs, so
  # a join to memberships on user_id alone gives each of user 1's posts
  # twice. Post 10 has two comments. editor_id and parent_id are NULL on some
  # posts, so a LEFT JOIN on them keeps those posts with NULLs. code is
  # unique but NULL on two posts.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.orgs (id int PRIMARY KEY, name text);
      CREATE TABLE public.users (id int PRIMARY KEY, name text, org_id int);
      CREATE TABLE public.posts (id int PRIMARY KEY, user_id int NOT NULL, editor_id int, parent_id int,
                                 title text, slug text NOT NULL UNIQUE, code text UNIQUE, tags int[]);
      CREATE TABLE public.comments (id int PRIMARY KEY, post_id int, body text);
      CREATE TABLE public.memberships (user_id int, org_id int, role text, PRIMARY KEY (user_id, org_id));
      CREATE TABLE public.wide (id bigint PRIMARY KEY, name text);
      INSERT INTO public.orgs VALUES (5, 'five'), (6, 'six');
      INSERT INTO public.users VALUES (1, 'ann', 5), (2, 'bob', 5), (3, 'ann', 6);
      INSERT INTO public.posts VALUES
        (10, 1, 2, NULL, 'same', 's10', NULL, '{1,1}'), (11, 1, NULL, 10, 'same', 's11', NULL, '{2}'),
        (12, 2, 1, 10, 'other', 's12', 'c12', '{3}'), (13, 3, NULL, NULL, 'same', 's13', 'c13', '{4}');
      INSERT INTO public.comments VALUES (1, 10, 'x'), (2, 10, 'y'), (3, 12, 'z');
      INSERT INTO public.memberships VALUES (1, 5, 'admin'), (1, 6, 'member'), (2, 5, 'member'), (3, 6, 'admin');
      INSERT INTO public.wide VALUES (1, 'one'), (2, 'two');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  # The rule's rewrites of sql, each as SQL.
  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def assumptions(sql) = rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)

  def ordered_rows(sql, params = []) = conn.exec_params(sql, params).values
  def rows(sql, params = []) = ordered_rows(sql, params).sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the
  # same multiset of them.
  def same_rows(sql, rewrites, params = [])
    expected = rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  # The same, for rows in the order the server gives them.
  def same_ordered_rows(sql, rewrites, params = [])
    expected = ordered_rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(ordered_rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  # As input qualifies it.
  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  # Every row of sql with its DISTINCT taken out by hand, to show what the
  # rule would give if it fired where it mustn't.
  def without_distinct(sql) = rows(sql.sub("SELECT DISTINCT", "SELECT"))

  fires = "SELECT DISTINCT p.id, p.title, u.name FROM public.posts p JOIN public.users u ON u.id = p.user_id " \
          "WHERE u.org_id = 5"
  let(:fires) { fires }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["distinct_key_removal",
       "A SELECT DISTINCT loses its DISTINCT when its select list holds a unique, not-null key of its first table " \
       "and each of its joins matches at most one row, by a unique key of the joined table."]
    )
  end

  it "drops the DISTINCT and leaves the rest of the query as it was" do
    rewrites = rewritten(fires)

    expect(rewrites).to eq(
      ["SELECT p.id, p.title, u.name FROM public.posts p JOIN public.users u ON u.id = p.user_id WHERE u.org_id = 5"]
    )
    expect(same_rows(fires, rewrites)).to eq([%w[10 same ann], %w[11 same ann], %w[12 other bob]])
  end

  it "states the first table's key unique and not null, and the joined table's key unique" do
    expect(assumptions(fires)).to eq(
      [[{ "kind" => "unique", "table" => "public.posts", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "id" },
        { "kind" => "unique", "table" => "public.users", "columns" => ["id"] }]]
    )
  end

  it "states only assumptions the catalog proves, so assumption-check accepts them" do
    stated = assumptions(fires).flatten(1)

    expect(stated.map { Quaack::Enclave::AssumptionCheck.met?(it, conn) }).to eq([true, true, true])
  end

  it "doesn't change the parse it was given" do
    parse = PgQuery.parse(fires)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog).size).to eq(1)

    expect(parse.tree).to eq(before)
  end

  it "takes Rails' .distinct over a to-one join: unaliased tables, a star, the key on the left, and a parameter" do
    sql = qualified('SELECT DISTINCT "posts".* FROM "posts" INNER JOIN "users" ON "users"."id" = "posts"."user_id" ' \
                    'WHERE "users"."name" = $1')

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT posts.* FROM public.posts JOIN public.users ON users.id = posts.user_id WHERE users.name = $1"]
    )
    expect(same_rows(sql, rewrites, ["ann"]).map(&:first)).to eq(%w[10 11 13])
  end

  it "takes the key on either side of the join's =, and another condition in the ON beside it" do
    sql = "SELECT DISTINCT p.id, u.name FROM public.posts p JOIN public.users u ON p.user_id = u.id AND u.name = 'ann'"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT p.id, u.name FROM public.posts p JOIN public.users u ON p.user_id = u.id AND u.name = 'ann'"]
    )
    expect(same_rows(sql, rewrites)).to eq([%w[10 ann], %w[11 ann], %w[13 ann]])
  end

  it "takes a LEFT JOIN on a nullable column, which keeps the rows it doesn't match" do
    sql = "SELECT DISTINCT p.title, p.id, e.name FROM public.posts p LEFT JOIN public.users e ON e.id = p.editor_id"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT p.title, p.id, e.name FROM public.posts p LEFT JOIN public.users e ON e.id = p.editor_id"]
    )
    expect(same_rows(sql, rewrites)).to eq([%w[other 12 ann], %w[same 10 bob], ["same", "11", nil],
                                            ["same", "13", nil]])
  end

  it "takes a chain of joins, each on a key paired with a table before it, and states every key" do
    sql = "SELECT DISTINCT p.id, o.name, m.role FROM public.posts p JOIN public.users u ON u.id = p.user_id " \
          "LEFT JOIN public.orgs o ON o.id = u.org_id " \
          "JOIN public.memberships m ON m.user_id = p.user_id AND m.org_id = u.org_id"

    rewrites = rewritten(sql)

    expect(rewrites).to eq([sql.sub("SELECT DISTINCT", "SELECT")])
    expect(assumptions(sql)).to eq(
      [[{ "kind" => "unique", "table" => "public.posts", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "id" },
        { "kind" => "unique", "table" => "public.users", "columns" => ["id"] },
        { "kind" => "unique", "table" => "public.orgs", "columns" => ["id"] },
        { "kind" => "unique", "table" => "public.memberships", "columns" => %w[user_id org_id] }]]
    )
    expect(same_rows(sql, rewrites)).to eq([%w[10 five admin], %w[11 five admin], %w[12 five member],
                                            %w[13 six admin]])
  end

  it "takes a self-join to the parent row, stating the key once" do
    sql = "SELECT DISTINCT p.id, parent.title FROM public.posts p LEFT JOIN public.posts parent " \
          "ON parent.id = p.parent_id"

    expect(assumptions(sql)).to eq(
      [[{ "kind" => "unique", "table" => "public.posts", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "id" }]]
    )
    expect(same_rows(sql, rewritten(sql))).to eq([["10", nil], %w[11 same], %w[12 same], ["13", nil]])
  end

  it "takes one table with no join" do
    sql = "SELECT DISTINCT p.title, p.id FROM public.posts p WHERE p.user_id = 1"

    expect(rewritten(sql)).to eq(["SELECT p.title, p.id FROM public.posts p WHERE p.user_id = 1"])
    expect(same_rows(sql, rewritten(sql))).to eq([%w[same 10], %w[same 11]])
  end

  it "keeps the ORDER BY, LIMIT, and OFFSET" do
    sql = "SELECT DISTINCT p.*, u.name FROM public.posts p JOIN public.users u ON u.id = p.user_id " \
          "ORDER BY u.name, p.id DESC LIMIT 2 OFFSET 1"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT p.*, u.name FROM public.posts p JOIN public.users u ON u.id = p.user_id " \
       "ORDER BY u.name, p.id DESC LIMIT 2 OFFSET 1"]
    )
    expect(same_ordered_rows(sql, rewrites).map(&:first)).to eq(%w[11 10])
  end

  it "takes a key that isn't the primary key, and one aliased in the select list" do
    sql = "SELECT DISTINCT p.title, p.slug AS s FROM public.posts p"

    expect(assumptions(sql)).to eq(
      [[{ "kind" => "unique", "table" => "public.posts", "columns" => ["slug"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "slug" }]]
    )
    expect(same_rows(sql, rewritten(sql)).size).to eq(4)
  end

  # id and slug are both proven keys of posts.
  {
    "p.id, p.slug" => "id",
    "p.slug, p.id" => "slug",
    "p.title, p.slug, p.id" => "slug",
    "p.*" => "id"
  }.each do |list, key|
    it "states the first of two proven keys in the select list: #{key} for #{list}" do
      expect(assumptions("SELECT DISTINCT #{list} FROM public.posts p")).to eq(
        [[{ "kind" => "unique", "table" => "public.posts", "columns" => [key] },
          { "kind" => "not_null", "table" => "public.posts", "column" => key }]]
      )
    end
  end

  it "takes a SELECT DISTINCT at any depth, one rewrite each, and the generator's second pass takes both" do
    inner = "SELECT DISTINCT p.* FROM public.posts p JOIN public.users u ON u.id = p.user_id WHERE u.org_id = 5"
    other = "SELECT DISTINCT p.* FROM public.posts p WHERE p.user_id = 3"
    sql = "SELECT count(*) FROM (#{inner} UNION ALL #{other}) subquery_for_count"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT count(*) FROM (#{inner.sub("DISTINCT ", "")} UNION ALL #{other}) subquery_for_count",
       "SELECT count(*) FROM (#{inner} UNION ALL #{other.sub("DISTINCT ", "")}) subquery_for_count"]
    )
    expect(same_rows(sql, rewrites)).to eq([["4"]])
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog, rules: [rule])
    expect(generated.rewrites.map(&:sql)).to include(sql.gsub("DISTINCT ", ""))
  end

  refusals = {
    "the select list holds no key" => "SELECT DISTINCT p.title FROM public.posts p",
    "the select list holds only part of a key" =>
      "SELECT DISTINCT m.role, m.org_id FROM public.memberships m",
    "the key is in the select list only inside an expression" =>
      "SELECT DISTINCT p.id + 0, p.title FROM public.posts p",
    "the key is cast" => "SELECT DISTINCT p.id::text, p.title FROM public.posts p",
    "the select list holds only a bare star" => "SELECT DISTINCT * FROM public.posts p",
    "the key is a joined table's" =>
      "SELECT DISTINCT u.id, p.title FROM public.posts p JOIN public.users u ON u.id = p.user_id",
    "the star is a joined table's" =>
      "SELECT DISTINCT u.*, p.title FROM public.posts p JOIN public.users u ON u.id = p.user_id",
    "the unique key is nullable" => "SELECT DISTINCT p.code FROM public.posts p",
    "the join can match many rows" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.comments c ON c.post_id = p.id",
    "the join pairs only part of the joined table's key" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.memberships m ON m.user_id = p.user_id",
    "the join pairs the key with a column of the joined table itself" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id = u.org_id",
    "the ON's = compares two columns of a table before it, one named as the key is" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON p.id = p.id",
    "the join pairs the key with a constant" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id = 1",
    "the join's key equality is under an OR" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id = p.user_id OR u.id = p.editor_id",
    "the join's key is compared by IS DISTINCT FROM" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.users u ON u.id IS DISTINCT FROM p.user_id",
    "the join's = names its schema" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id OPERATOR(pg_catalog.=) p.user_id",
    "a join column is cast" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id = p.user_id::int",
    "the join's columns differ in type" =>
      "SELECT DISTINCT p.id, w.name FROM public.posts p JOIN public.wide w ON w.id = p.user_id",
    "it's a cross join" => "SELECT DISTINCT p.id FROM public.posts p CROSS JOIN public.orgs o",
    "it's a comma join" =>
      "SELECT DISTINCT p.id FROM public.posts p, public.users u WHERE u.id = p.user_id",
    "it's a RIGHT JOIN" =>
      "SELECT DISTINCT p.id FROM public.users u RIGHT JOIN public.posts p ON u.id = p.user_id",
    "it's a FULL JOIN" =>
      "SELECT DISTINCT p.id, u.name FROM public.posts p FULL JOIN public.users u ON u.id = p.user_id",
    "the join is USING" => "SELECT DISTINCT p.id FROM public.posts p JOIN public.comments c USING (id)",
    "the join is NATURAL" => "SELECT DISTINCT p.id FROM public.posts p NATURAL JOIN public.comments c",
    "the join has an alias" =>
      "SELECT DISTINCT j.id FROM (public.posts p JOIN public.users u ON u.id = p.user_id) j",
    "the join has an alias that names another column as the key" =>
      "SELECT DISTINCT p.slug FROM (public.posts p JOIN public.users u ON u.id = p.user_id) " \
      "AS p (i, slug, e, pa, t, s)",
    "a join is nested on the right" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN (public.users u JOIN public.orgs o ON o.id = u.org_id) " \
      "ON u.id = p.user_id",
    "the joined table is read with ONLY" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN ONLY public.users u ON u.id = p.user_id",
    "the first table is a subquery" => "SELECT DISTINCT s.id FROM (SELECT p.id FROM public.posts p) s",
    "the first table has column aliases, so p.id may be another column" =>
      "SELECT DISTINCT p.id FROM public.posts p (user_id, id)",
    "a table isn't schema-qualified, so it may be a CTE" =>
      "WITH posts AS (SELECT * FROM public.posts) SELECT DISTINCT posts.id FROM posts",
    "two FROM items share a name" =>
      "SELECT DISTINCT p.id FROM public.posts p JOIN public.users p ON p.id = p.user_id",
    "it's DISTINCT ON" => "SELECT DISTINCT ON (p.title) p.id, p.title FROM public.posts p",
    "it has a GROUP BY" => "SELECT DISTINCT p.id, p.title FROM public.posts p GROUP BY p.id",
    "it has grouping sets" => "SELECT DISTINCT p.id FROM public.posts p GROUP BY ROLLUP (p.id, p.title)",
    "the select list has a window function" =>
      "SELECT DISTINCT p.id, count(*) OVER () FROM public.posts p",
    "the select list has a set-returning function" =>
      "SELECT DISTINCT p.id, unnest(p.tags) FROM public.posts p",
    "the select list has an aggregate in a subquery" =>
      "SELECT DISTINCT p.id, (SELECT count(*) FROM public.comments c WHERE c.post_id = p.id) FROM public.posts p",
    "it locks rows" => "SELECT DISTINCT p.id FROM public.posts p FOR UPDATE",
    "it's plain, with no DISTINCT" => "SELECT p.id FROM public.posts p",
    "the join pairs the key with a column of an outer query" =>
      "SELECT o.id FROM public.orgs o WHERE EXISTS " \
      "(SELECT DISTINCT p.id FROM public.posts p JOIN public.users u ON u.id = o.id)"
  }

  refusals.each do |why, sql|
    it "doesn't fire when #{why}" do
      expect(rewritten(sql)).to eq([])
    end
  end

  # What the rule would give if it fired where it refuses, against what the
  # original gives: the DISTINCT removes rows in each.
  {
    "a select list without a key" => "SELECT DISTINCT p.title FROM public.posts p",
    "a unique key that's nullable" => "SELECT DISTINCT p.code FROM public.posts p",
    "a join that matches many rows" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.comments c ON c.post_id = p.id",
    "a join on part of a key" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.memberships m ON m.user_id = p.user_id",
    "a set-returning function" => "SELECT DISTINCT p.id, unnest(p.tags) FROM public.posts p",
    "grouping sets" => "SELECT DISTINCT p.id FROM public.posts p GROUP BY ROLLUP (p.id, p.title)",
    "column aliases that rename the key" => "SELECT DISTINCT p.id FROM public.posts p (user_id, id)",
    "a join alias that renames the key" =>
      "SELECT DISTINCT p.slug FROM (public.posts p JOIN public.users u ON u.id = p.user_id) " \
      "AS p (i, slug, e, pa, t, s)",
    "a key of the joined table" =>
      "SELECT DISTINCT u.id, p.title FROM public.posts p JOIN public.users u ON u.id = p.user_id",
    "a star of the joined table" =>
      "SELECT DISTINCT u.*, p.title FROM public.posts p JOIN public.users u ON u.id = p.user_id",
    "a join by IS DISTINCT FROM" =>
      "SELECT DISTINCT p.id, p.title FROM public.posts p JOIN public.users u ON u.id IS DISTINCT FROM p.user_id"
  }.each do |why, sql|
    it "would be wrong on #{why}: the DISTINCT removes rows" do
      expect(without_distinct(sql).size).to be > rows(sql).size
    end
  end

  context "with collations and key indexes" do
    it "fires on text keys with a deterministic collation" do
      conn.exec(<<~SQL)
        CREATE TABLE public.codes (code text COLLATE "C" PRIMARY KEY, label text);
        CREATE TABLE public.coded (id int PRIMARY KEY, code text COLLATE "C");
        INSERT INTO public.codes VALUES ('a', 'A'), ('b', 'B');
        INSERT INTO public.coded VALUES (1, 'a'), (2, 'a'), (3, NULL);
      SQL
      sql = "SELECT DISTINCT d.id, c.label FROM public.coded d LEFT JOIN public.codes c ON c.code = d.code"

      expect(rewritten(sql)).to eq([sql.sub("DISTINCT ", "")])
      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 A], %w[2 A], ["3", nil]])
    end

    it "doesn't fire on a join on columns with a nondeterministic collation" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.tags (name text COLLATE public.ci PRIMARY KEY);
        CREATE TABLE public.taggings (id int PRIMARY KEY, tag text COLLATE public.ci);
      SQL

      expect(rewritten("SELECT DISTINCT g.id FROM public.taggings g JOIN public.tags t ON t.name = g.tag")).to eq([])
    end

    it "doesn't fire on a key whose unique index compares in another collation than DISTINCT does" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.handles (name text COLLATE public.ci NOT NULL, note text);
        CREATE UNIQUE INDEX handles_name ON public.handles (name COLLATE "C");
        INSERT INTO public.handles VALUES ('Ann', 'x'), ('ann', 'x');
      SQL
      sql = "SELECT DISTINCT h.name FROM public.handles h"

      expect(rewritten(sql)).to eq([])
      expect(without_distinct(sql).size).to be > rows(sql).size
    end

    it "doesn't fire when only the joined key's collation is nondeterministic" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.tags (name text COLLATE public.ci PRIMARY KEY);
        CREATE TABLE public.taggings (id int PRIMARY KEY, tag text);
      SQL

      expect(rewritten("SELECT DISTINCT g.id FROM public.taggings g JOIN public.tags t ON t.name = g.tag")).to eq([])
    end

    it "doesn't fire when only the joining column's collation is nondeterministic" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.tags (name text PRIMARY KEY);
        CREATE TABLE public.taggings (id int PRIMARY KEY, tag text COLLATE public.ci);
      SQL

      expect(rewritten("SELECT DISTINCT g.id FROM public.taggings g JOIN public.tags t ON t.name = g.tag")).to eq([])
    end

    it "doesn't fire on a join whose = isn't the key index's, such as a domain's own" do
      conn.exec(<<~SQL)
        CREATE DOMAIN public.digit AS int;
        CREATE FUNCTION public.digit_eq(public.digit, public.digit) RETURNS boolean
          LANGUAGE sql IMMUTABLE AS 'SELECT $1 % 10 = $2 % 10';
        CREATE OPERATOR public.= (LEFTARG = public.digit, RIGHTARG = public.digit, FUNCTION = public.digit_eq);
        CREATE TABLE public.digits (d public.digit PRIMARY KEY, label text);
        CREATE TABLE public.readings (id int PRIMARY KEY, d public.digit);
        INSERT INTO public.digits VALUES (3, 'three'), (13, 'thirteen');
        INSERT INTO public.readings VALUES (1, 3);
      SQL
      sql = "SELECT DISTINCT r.id FROM public.readings r JOIN public.digits g ON g.d = r.d"

      expect(catalog.met?({ "kind" => "unique", "table" => "public.digits", "columns" => ["d"] })).to be(true)
      expect(rewritten(sql)).to eq([])
      expect(without_distinct(sql).size).to be > rows(sql).size
    end

    it "doesn't fire on a key with a nondeterministic collation, even one its unique index shares" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.handles (name text COLLATE public.ci PRIMARY KEY, note text);
      SQL

      expect(catalog.met?({ "kind" => "unique", "table" => "public.handles", "columns" => ["name"] })).to be(true)
      expect(rewritten("SELECT DISTINCT h.name, h.note FROM public.handles h")).to eq([])
    end

    it "doesn't fire on a nullable key, even one whose unique index treats NULLs as equal" do
      conn.exec(<<~SQL)
        CREATE TABLE public.badges (code text, note text);
        CREATE UNIQUE INDEX badges_code ON public.badges (code) NULLS NOT DISTINCT;
      SQL

      expect(catalog.met?({ "kind" => "unique", "table" => "public.badges", "columns" => ["code"] })).to be(true)
      expect(rewritten("SELECT DISTINCT b.code, b.note FROM public.badges b")).to eq([])
    end

    it "doesn't fire on a key whose unique index is partial" do
      conn.exec(<<~SQL)
        CREATE TABLE public.drafts (id int NOT NULL, state text);
        CREATE UNIQUE INDEX drafts_id ON public.drafts (id) WHERE state = 'live';
      SQL

      expect(rewritten("SELECT DISTINCT d.id FROM public.drafts d")).to eq([])
    end

    it "doesn't fire on a joined table whose unique index is partial" do
      conn.exec(<<~SQL)
        CREATE TABLE public.drafts (id int NOT NULL, state text);
        CREATE UNIQUE INDEX drafts_id ON public.drafts (id) WHERE state = 'live';
      SQL

      expect(rewritten("SELECT DISTINCT p.id FROM public.posts p JOIN public.drafts d ON d.id = p.id")).to eq([])
    end
  end

  context "with a schema other than public" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA app;
        CREATE TABLE app.users (id int PRIMARY KEY, name text);
        CREATE TABLE app.posts (id int PRIMARY KEY, user_id int);
      SQL
    end

    it "names that schema's tables in the assumptions" do
      sql = "SELECT DISTINCT p.id, u.name FROM app.posts p JOIN app.users u ON u.id = p.user_id"

      expect(assumptions(sql)).to eq(
        [[{ "kind" => "unique", "table" => "app.posts", "columns" => ["id"] },
          { "kind" => "not_null", "table" => "app.posts", "column" => "id" },
          { "kind" => "unique", "table" => "app.users", "columns" => ["id"] }]]
      )
    end
  end
end
