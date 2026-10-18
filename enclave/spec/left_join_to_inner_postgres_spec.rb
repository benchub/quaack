# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' left_join_to_inner, on a real server: what it
# writes, that its output returns the rows its input does, with the same
# multiplicity, and that it fires only when the catalog proves a validated,
# immediate, enforced foreign key on not-null columns of a table the join's
# left side can't fill with NULLs.
RSpec.describe Quaack::Enclave::RewriteRules::LeftJoinToInner do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # User 1 has two posts, so a join that dropped duplicates would show; user
  # 3 has none. editor_id is nullable and NULL on post 12, so an inner join
  # on it would drop that row. orphans' user_id has no foreign key, and
  # comments' NOT VALID one, and both hold a row whose user doesn't exist.
  # Orphan 2 has no post with id 11 times its own, so an inner join after a
  # LEFT JOIN from orphans to posts would drop it.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.orgs (id int PRIMARY KEY, name text);
      CREATE TABLE public.users (id int PRIMARY KEY, name text, org int NOT NULL REFERENCES public.orgs,
                                 UNIQUE (org, id));
      CREATE TABLE public.posts (id int PRIMARY KEY, user_id int NOT NULL REFERENCES public.users,
                                 editor_id int REFERENCES public.users, org int NOT NULL, title text,
                                 FOREIGN KEY (org, user_id) REFERENCES public.users (org, id));
      INSERT INTO public.orgs VALUES (5, 'acme'), (6, 'initech');
      INSERT INTO public.users VALUES (1, 'ann', 5), (2, 'bob', 5), (3, 'cy', 6);
      INSERT INTO public.posts VALUES (10, 1, 2, 5, 'a'), (11, 1, 1, 5, 'b'), (12, 2, NULL, 5, 'c');
      CREATE TABLE public.orphans (id int PRIMARY KEY, user_id int NOT NULL);
      INSERT INTO public.orphans VALUES (1, 1), (2, 99);
      CREATE TABLE public.comments (id int PRIMARY KEY, user_id int NOT NULL);
      INSERT INTO public.comments VALUES (1, 1), (2, 99);
      ALTER TABLE public.comments ADD FOREIGN KEY (user_id) REFERENCES public.users NOT VALID;
      CREATE TABLE public.deferred (id int PRIMARY KEY,
                                    user_id int NOT NULL REFERENCES public.users DEFERRABLE INITIALLY DEFERRED);
      INSERT INTO public.deferred VALUES (1, 1);
      CREATE TABLE public.wide (id bigint PRIMARY KEY);
      CREATE TABLE public.narrow (id int PRIMARY KEY, wide_id int NOT NULL REFERENCES public.wide);
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql, params = []) = conn.exec_params(sql, params).values.sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the
  # same multiset of them.
  def same_rows(sql, rewrites, params = [])
    expected = rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  def qualified(sql) = Quaack::Enclave::RelationQualifier.qualify(sql, nil, conn).sql

  fires = "SELECT p.id, u.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id"
  let(:fires) { fires }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["left_join_to_inner",
       "A LEFT JOIN on a validated foreign key whose columns are all not null, from a table the join's left " \
       "side can't fill with NULLs, becomes an inner join."]
    )
  end

  it "makes the LEFT JOIN inner, leaving the rest of the query as it was" do
    rewrites = rewritten(fires)

    expect(rewrites).to eq(["SELECT p.id, u.name FROM public.posts p JOIN public.users u ON p.user_id = u.id"])
    expect(same_rows(fires, rewrites)).to eq([%w[10 ann], %w[11 ann], %w[12 bob]])
  end

  it "states the foreign key and each of its columns not null, in assumption-check's vocabulary" do
    expect(rule.rewrites(PgQuery.parse(fires), catalog).map(&:assumptions)).to eq(
      [[{ "kind" => "foreign_key", "table" => "public.posts", "columns" => ["user_id"],
          "references_table" => "public.users", "references_columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "user_id" }]]
    )
  end

  it "states only assumptions the catalog proves, so assumption-check accepts them" do
    assumptions = rule.rewrites(PgQuery.parse(fires), catalog).flat_map(&:assumptions)

    expect(assumptions.map { Quaack::Enclave::AssumptionCheck.met?(it, conn) }).to eq([true, true])
  end

  it "doesn't change the parse it was given" do
    parse = PgQuery.parse(fires)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog).size).to eq(1)

    expect(parse.tree).to eq(before)
  end

  it "takes Rails' eager_load: unaliased tables, the key on the left, an order on the association, and a LIMIT" do
    sql = qualified('SELECT "posts"."id" AS t0_r0, "posts"."title" AS t0_r1, "users"."id" AS t1_r0, ' \
                    '"users"."name" AS t1_r1 FROM "posts" ' \
                    'LEFT OUTER JOIN "users" ON "users"."id" = "posts"."user_id" ' \
                    'WHERE "posts"."org" = $1 ORDER BY users.name DESC, "posts"."id" ASC LIMIT $2')

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT posts.id AS t0_r0, posts.title AS t0_r1, users.id AS t1_r0, users.name AS t1_r1 FROM public.posts " \
       "JOIN public.users ON users.id = posts.user_id WHERE posts.org = $1 ORDER BY users.name DESC, posts.id ASC " \
       "LIMIT $2"]
    )
    expect(conn.exec_params(rewrites.first, [5, 2]).values).to eq(conn.exec_params(sql, [5, 2]).values)
    expect(conn.exec_params(sql, [5, 2]).values).to eq([%w[12 c 2 bob], %w[10 a 1 ann]])
  end

  it "takes a foreign key of two columns, joined on both" do
    sql = "SELECT p.id, u.name FROM public.posts p LEFT JOIN public.users u ON p.org = u.org AND u.id = p.user_id"

    expect(rewritten(sql)).to eq(
      ["SELECT p.id, u.name FROM public.posts p JOIN public.users u ON p.org = u.org AND u.id = p.user_id"]
    )
    expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions).to eq(
      [{ "kind" => "foreign_key", "table" => "public.posts", "columns" => %w[org user_id],
         "references_table" => "public.users", "references_columns" => %w[org id] },
       { "kind" => "not_null", "table" => "public.posts", "column" => "org" },
       { "kind" => "not_null", "table" => "public.posts", "column" => "user_id" }]
    )
  end

  it "takes a join in a subquery, a CTE, and one on another outer join's nullable side" do
    sub = "SELECT o.id FROM public.orphans o WHERE o.user_id IN " \
          "(SELECT p.user_id FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id WHERE u.name <> 'z')"
    cte = "WITH x AS (SELECT p.id, u.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id) " \
          "SELECT x.name FROM x"
    nested = "SELECT o.id, p.id, u.name FROM public.orphans o LEFT JOIN " \
             "(public.posts p LEFT JOIN public.users u ON p.user_id = u.id) ON p.id = o.id * 11"

    expect(rewritten(sub)).to eq(
      ["SELECT o.id FROM public.orphans o WHERE o.user_id IN " \
       "(SELECT p.user_id FROM public.posts p JOIN public.users u ON p.user_id = u.id WHERE u.name <> 'z')"]
    )
    expect(rewritten(cte)).to eq(
      ["WITH x AS (SELECT p.id, u.name FROM public.posts p JOIN public.users u ON p.user_id = u.id) " \
       "SELECT x.name FROM x"]
    )
    expect(rewritten(nested)).to eq(
      ["SELECT o.id, p.id, u.name FROM public.orphans o LEFT JOIN " \
       "(public.posts p JOIN public.users u ON p.user_id = u.id) ON p.id = (o.id * 11)"]
    )
    expect(same_rows(sub, rewritten(sub))).to eq([["1"]])
    expect(same_rows(cte, rewritten(cte))).to eq([["ann"], ["ann"], ["bob"]])
    expect(same_rows(nested, rewritten(nested))).to eq([%w[1 11 ann], ["2", nil, nil]])
  end

  it "takes a left side that joins the table to others, inner or as an outer join's preserved side" do
    inner = "SELECT o.id, u.name FROM public.orphans o JOIN public.posts p ON p.id = o.id + 9 " \
            "LEFT JOIN public.users u ON u.id = p.user_id"
    preserved = "SELECT p.id, o.id, u.name FROM public.posts p LEFT JOIN public.orphans o ON o.id = p.id - 9 " \
                "LEFT JOIN public.users u ON u.id = p.user_id"

    expect(rewritten(inner)).to eq(
      ["SELECT o.id, u.name FROM public.orphans o JOIN public.posts p ON p.id = (o.id + 9) " \
       "JOIN public.users u ON u.id = p.user_id"]
    )
    expect(rewritten(preserved)).to eq(
      ["SELECT p.id, o.id, u.name FROM public.posts p LEFT JOIN public.orphans o ON o.id = (p.id - 9) " \
       "JOIN public.users u ON u.id = p.user_id"]
    )
    expect(same_rows(inner, rewritten(inner))).to eq([%w[1 ann], %w[2 ann]])
    expect(same_rows(preserved, rewritten(preserved)).size).to eq(3)
  end

  it "takes a join with an alias, which hides nothing its ON reads" do
    sql = "SELECT j.title, j.name FROM (public.posts p LEFT JOIN public.users u ON p.user_id = u.id) j"

    # pg_query's deparse puts a space before the alias's parenthesis.
    expect(rewritten(sql)).to eq(
      ["SELECT j.title, j.name FROM (public.posts p JOIN public.users u ON p.user_id = u.id ) j"]
    )
    expect(same_rows(sql, rewritten(sql))).to eq([%w[a ann], %w[b ann], %w[c bob]])
  end

  it "gives one rewrite per join it can make inner, outermost first, and the generator's second pass makes both" do
    sql = "SELECT p.id, u.name, v.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id " \
          "LEFT JOIN public.users e ON e.id = p.editor_id LEFT JOIN public.users v ON v.id = p.user_id"

    expect(rewritten(sql)).to eq(
      ["SELECT p.id, u.name, v.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id " \
       "LEFT JOIN public.users e ON e.id = p.editor_id JOIN public.users v ON v.id = p.user_id",
       "SELECT p.id, u.name, v.name FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
       "LEFT JOIN public.users e ON e.id = p.editor_id LEFT JOIN public.users v ON v.id = p.user_id"]
    )
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog, rules: [rule])
    expect(generated.rewrites.map(&:sql)).to include(
      "SELECT p.id, u.name, v.name FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
      "LEFT JOIN public.users e ON e.id = p.editor_id JOIN public.users v ON v.id = p.user_id"
    )
  end

  it "makes a join from a table another LEFT JOIN brings in inner only once that join is inner" do
    sql = "SELECT p.id, g.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id " \
          "LEFT JOIN public.orgs g ON g.id = u.org"
    both = "SELECT p.id, g.name FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
           "JOIN public.orgs g ON g.id = u.org"

    expect(rewritten(sql)).to eq(
      ["SELECT p.id, g.name FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
       "LEFT JOIN public.orgs g ON g.id = u.org"]
    )
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog, rules: [rule])
    expect(generated.rewrites.map(&:sql)).to include(both)
    expect(same_rows(sql, [both])).to eq([%w[10 acme], %w[11 acme], %w[12 acme]])
  end

  it "takes a self-referencing foreign key" do
    conn.exec(<<~SQL)
      CREATE TABLE public.employees (id int PRIMARY KEY, name text, manager_id int NOT NULL REFERENCES public.employees);
      INSERT INTO public.employees VALUES (1, 'ann', 1), (2, 'bob', 1), (3, 'cy', 2);
    SQL
    sql = "SELECT e.name, m.name FROM public.employees e LEFT JOIN public.employees m ON e.manager_id = m.id"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT e.name, m.name FROM public.employees e JOIN public.employees m ON e.manager_id = m.id"]
    )
    expect(same_rows(sql, rewrites)).to eq([%w[ann ann], %w[bob ann], %w[cy bob]])
  end

  it "takes the same join in each branch of a UNION ALL, one rewrite per branch" do
    branch = "SELECT u.name FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id WHERE p.id = "
    inner = "SELECT u.name FROM public.posts p JOIN public.users u ON p.user_id = u.id WHERE p.id = "
    sql = "#{branch}10 UNION ALL #{branch}12"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(["#{inner}10 UNION ALL #{branch}12", "#{branch}10 UNION ALL #{inner}12"])
    expect(same_rows(sql, rewrites)).to eq([["ann"], ["bob"]])
  end

  refusals = {
    "the join is on a nullable column" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u " \
                                          "ON p.editor_id = u.id",
    "there's no foreign key" => "SELECT o.id FROM public.orphans o LEFT JOIN public.users u ON o.user_id = u.id",
    "the foreign key is NOT VALID" => "SELECT c.id FROM public.comments c LEFT JOIN public.users u " \
                                      "ON c.user_id = u.id",
    "the foreign key is deferrable" => "SELECT d.id FROM public.deferred d LEFT JOIN public.users u " \
                                       "ON d.user_id = u.id",
    "the join covers only some of a foreign key's columns" => "SELECT p.id FROM public.posts p " \
                                                              "LEFT JOIN public.users u ON p.org = u.org",
    "the join pairs the wrong columns" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u " \
                                          "ON p.user_id = u.org",
    "the foreign key points the other way" => "SELECT u.id FROM public.users u LEFT JOIN public.posts p " \
                                              "ON p.user_id = u.id",
    "the columns' types differ" => "SELECT n.id FROM public.narrow n LEFT JOIN public.wide w ON n.wide_id = w.id",
    "the ON holds another condition on the joined table" => "SELECT p.id, u.name FROM public.posts p " \
                                                            "LEFT JOIN public.users u ON p.user_id = u.id " \
                                                            "AND u.name = 'ann'",
    "the ON holds a condition on the left side" => "SELECT p.id, u.name FROM public.posts p LEFT JOIN public.users u " \
                                                   "ON p.user_id = u.id AND p.title <> 'a'",
    "the ON is an OR" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u " \
                         "ON p.user_id = u.id OR p.editor_id = u.id",
    "the ON joins two tables of the left side" => "SELECT p.id FROM public.posts p JOIN public.orphans o " \
                                                  "ON o.id = p.id LEFT JOIN public.users u " \
                                                  "ON p.user_id = u.id AND o.user_id = u.id",
    "the ON is true" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u ON true",
    "a column is bare" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u ON user_id = u.id",
    "the comparison isn't a plain =" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u " \
                                        "ON p.user_id OPERATOR(pg_catalog.=) u.id",
    "a column is cast" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u ON p.user_id::bigint = u.id",
    "the joining table is on an outer join's nullable side" =>
      "SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id * 11 LEFT JOIN public.users u " \
      "ON p.user_id = u.id",
    "the joining table is on a FULL JOIN's side" =>
      "SELECT o.id FROM public.orphans o FULL JOIN public.posts p ON p.id = o.id * 11 LEFT JOIN public.users u " \
      "ON p.user_id = u.id",
    "an aliased join on the left side hides the joining table" =>
      "SELECT j.id FROM (public.posts p JOIN public.orphans o ON o.id = p.id) j LEFT JOIN public.users u " \
      "ON p.user_id = u.id",
    "the joining side is a subquery" => "SELECT p.id FROM (SELECT * FROM public.posts) p LEFT JOIN public.users u " \
                                        "ON p.user_id = u.id",
    "the joined side is a subquery" => "SELECT p.id FROM public.posts p LEFT JOIN (SELECT * FROM public.users) u " \
                                       "ON p.user_id = u.id",
    "the joined side is a join" => "SELECT p.id FROM public.posts p LEFT JOIN (public.users u JOIN public.orgs g " \
                                   "ON g.id = u.org) ON p.user_id = u.id",
    "the joined table is read with ONLY" => "SELECT p.id FROM public.posts p LEFT JOIN ONLY public.users u " \
                                            "ON p.user_id = u.id",
    "the joined table has column aliases" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u (id) " \
                                             "ON p.user_id = u.id",
    "it's a RIGHT JOIN, which keeps the joined table's rows" => "SELECT u.id FROM public.posts p " \
                                                                "RIGHT JOIN public.users u ON p.user_id = u.id",
    "it's a RIGHT JOIN written the other way round" => "SELECT p.id FROM public.users u RIGHT JOIN public.posts p " \
                                                       "ON p.user_id = u.id",
    "it's a FULL JOIN" => "SELECT p.id FROM public.posts p FULL JOIN public.users u ON p.user_id = u.id",
    "it's already an inner join" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id",
    "the join is USING" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u USING (id)",
    "the join is NATURAL" => "SELECT p.id FROM public.posts p NATURAL LEFT JOIN public.users u",
    "the query locks rows" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id " \
                              "FOR UPDATE OF p"
  }

  refusals.each do |why, sql|
    it "doesn't fire when #{why}" do
      expect(rewritten(sql)).to eq([])
    end
  end

  # Each pair: a query the rule refuses, and its inner join, which returns
  # other rows on this data.
  wrong = {
    "on a nullable column: the inner join drops the post whose column is NULL" =>
      ["SELECT p.id FROM public.posts p LEFT JOIN public.users u ON p.editor_id = u.id",
       "SELECT p.id FROM public.posts p JOIN public.users u ON p.editor_id = u.id"],
    "on a NOT VALID foreign key: the inner join drops the orphan" =>
      ["SELECT c.id FROM public.comments c LEFT JOIN public.users u ON c.user_id = u.id",
       "SELECT c.id FROM public.comments c JOIN public.users u ON c.user_id = u.id"],
    "on a joining table an outer join can fill with NULL: the inner join drops the row it filled" =>
      ["SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id * 11 LEFT JOIN public.users u " \
       "ON p.user_id = u.id",
       "SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id * 11 JOIN public.users u " \
       "ON p.user_id = u.id"],
    "with another condition on the joined table: the inner join drops the rows it fails" =>
      ["SELECT p.id FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id AND u.name = 'ann'",
       "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id AND u.name = 'ann'"],
    "on a RIGHT JOIN: the inner join drops the user with no posts" =>
      ["SELECT u.id FROM public.posts p RIGHT JOIN public.users u ON p.user_id = u.id",
       "SELECT u.id FROM public.posts p JOIN public.users u ON p.user_id = u.id"]
  }

  wrong.each do |why, (sql, inner)|
    it "would be wrong #{why}" do
      expect(rewritten(sql)).to eq([])
      expect(rows(inner).size).to be < rows(sql).size
    end
  end

  context "when the tables aren't plain" do
    it "doesn't fire on a joined table with row-level security, which the join filters by" do
      conn.exec("ALTER TABLE public.users ENABLE ROW LEVEL SECURITY")

      expect(rewritten(fires)).to eq([])
    end

    it "doesn't fire when the foreign key's triggers are disabled, so rows may break it" do
      conn.exec("ALTER TABLE public.posts DISABLE TRIGGER ALL")

      expect(rewritten(fires)).to eq([])
    end

    it "doesn't fire on a NOT ENFORCED foreign key" do
      conn.exec(<<~SQL)
        CREATE TABLE public.loose (id int PRIMARY KEY, user_id int NOT NULL);
        ALTER TABLE public.loose ADD FOREIGN KEY (user_id) REFERENCES public.users NOT ENFORCED;
      SQL

      expect(rewritten("SELECT l.id FROM public.loose l LEFT JOIN public.users u ON l.user_id = u.id")).to eq([])
    end

    it "doesn't fire on a joining table with inheritance children, whose rows the foreign key doesn't cover" do
      conn.exec(<<~SQL)
        CREATE TABLE public.uses (id int PRIMARY KEY, user_id int NOT NULL REFERENCES public.users);
        CREATE TABLE public.kid () INHERITS (public.uses);
        INSERT INTO public.kid VALUES (1, 99);
      SQL
      sql = "SELECT s.id FROM public.uses s LEFT JOIN public.users t ON s.user_id = t.id"

      expect(rows(sql)).to eq([["1"]])
      expect(rewritten(sql)).to eq([])
    end

    it "doesn't fire on a joined table that's a view" do
      conn.exec("CREATE VIEW public.people AS SELECT * FROM public.users")

      expect(rewritten("SELECT p.id FROM public.posts p LEFT JOIN public.people u ON p.user_id = u.id")).to eq([])
    end
  end

  context "with a schema other than public" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA app;
        CREATE TABLE app.users (id int PRIMARY KEY);
        CREATE TABLE app.posts (id int PRIMARY KEY, user_id int NOT NULL REFERENCES app.users);
      SQL
    end

    it "fires on that schema's tables, and names them by it in the assumptions" do
      sql = "SELECT p.id FROM app.posts p LEFT JOIN app.users u ON p.user_id = u.id"

      expect(rewritten(sql)).to eq(["SELECT p.id FROM app.posts p JOIN app.users u ON p.user_id = u.id"])
      expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions.first).to include(
        "table" => "app.posts", "references_table" => "app.users"
      )
    end

    it "doesn't fire across schemas when the foreign key points at the other one's table" do
      expect(rewritten("SELECT p.id FROM app.posts p LEFT JOIN public.users u ON p.user_id = u.id")).to eq([])
    end
  end
end
