# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/relation_qualifier"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' unused_join_removal, on a real server: what it writes,
# that its output returns the rows its input does, with the same
# multiplicity, and that it fires only when the catalog proves a validated,
# immediate, enforced foreign key on not-null columns and the joined table is
# read nowhere else.
RSpec.describe Quaack::Enclave::RewriteRules::UnusedJoinRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # User 1 has two posts, so a join that dropped duplicates would show; user
  # 3 has none. editor_id is nullable and NULL on post 12, so dropping a join
  # on it would add that row. orphans' user_id has no foreign key, and
  # comments' NOT VALID one, and both hold a row whose user doesn't exist.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, name text, org int NOT NULL, UNIQUE (org, id));
      CREATE TABLE public.posts (id int PRIMARY KEY, user_id int NOT NULL REFERENCES public.users,
                                 editor_id int REFERENCES public.users, org int NOT NULL, title text,
                                 FOREIGN KEY (org, user_id) REFERENCES public.users (org, id));
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

  fires = "SELECT p.id, p.title FROM public.posts p JOIN public.users u ON p.user_id = u.id WHERE p.title <> 'z'"
  let(:fires) { fires }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["unused_join_removal",
       "An inner join to a table the query reads nowhere else, on a validated foreign key whose columns are " \
       "all not null, is removed."]
    )
  end

  it "removes the joined table, leaving the rest of the query as it was" do
    rewrites = rewritten(fires)

    expect(rewrites).to eq(["SELECT p.id, p.title FROM public.posts p WHERE p.title <> 'z'"])
    expect(same_rows(fires, rewrites)).to eq([%w[10 a], %w[11 b], %w[12 c]])
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

  it "takes the ORM's shape: unaliased tables, a qualified star, the key on the left, and a parameter" do
    sql = qualified("SELECT posts.* FROM users INNER JOIN posts ON users.id = posts.user_id WHERE posts.org = $1")

    rewrites = rewritten(sql)

    expect(rewrites).to eq(["SELECT posts.* FROM public.posts WHERE posts.org = $1"])
    expect(same_rows(sql, rewrites, [5]).size).to eq(3)
  end

  it "takes a comma join whose WHERE holds the equality, and drops only that conjunct" do
    sql = "SELECT p.id FROM public.posts p, public.users u WHERE u.id = p.user_id AND p.org = 5"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(["SELECT p.id FROM public.posts p WHERE p.org = 5"])
    expect(same_rows(sql, rewrites)).to eq([["10"], ["11"], ["12"]])
  end

  it "takes a comma join whose WHERE is only the equality, leaving no WHERE" do
    sql = "SELECT count(*) FROM public.posts p, public.users u WHERE p.user_id = u.id"

    expect(same_rows(sql, rewritten(sql))).to eq([["3"]])
    expect(rewritten(sql)).to eq(["SELECT count(*) FROM public.posts p"])
  end

  it "takes a foreign key of two columns, joined on both" do
    sql = "SELECT p.id FROM public.posts p JOIN public.users u ON p.org = u.org AND u.id = p.user_id"

    expect(rewritten(sql)).to eq(["SELECT p.id FROM public.posts p"])
    expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions).to eq(
      [{ "kind" => "foreign_key", "table" => "public.posts", "columns" => %w[org user_id],
         "references_table" => "public.users", "references_columns" => %w[org id] },
       { "kind" => "not_null", "table" => "public.posts", "column" => "org" },
       { "kind" => "not_null", "table" => "public.posts", "column" => "user_id" }]
    )
  end

  it "takes a join in a subquery, and one inside another join" do
    sub = "SELECT o.id FROM public.orphans o WHERE o.user_id IN " \
          "(SELECT p.user_id FROM public.posts p JOIN public.users u ON p.user_id = u.id)"
    nested = "SELECT o.id, p.id FROM public.orphans o LEFT JOIN " \
             "(public.posts p JOIN public.users u ON p.user_id = u.id) ON p.id = o.id + 9"

    expect(rewritten(sub)).to eq(
      ["SELECT o.id FROM public.orphans o WHERE o.user_id IN (SELECT p.user_id FROM public.posts p)"]
    )
    expect(rewritten(nested)).to eq(
      ["SELECT o.id, p.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = (o.id + 9)"]
    )
    expect(same_rows(sub, rewritten(sub))).to eq([["1"]])
    expect(same_rows(nested, rewritten(nested))).to eq([%w[1 10], %w[2 11]])
  end

  it "gives one rewrite per removable join, and the generator's second pass removes both" do
    sql = "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
          "JOIN public.narrow n ON true JOIN public.users v ON v.id = p.user_id"

    expect(rewritten(sql)).to eq(
      ["SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id JOIN public.narrow n ON true",
       "SELECT p.id FROM public.posts p JOIN public.narrow n ON true JOIN public.users v ON v.id = p.user_id"]
    )
    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog, rules: [rule])
    expect(generated.rewrites.map(&:sql)).to include("SELECT p.id FROM public.posts p JOIN public.narrow n ON true")
  end

  refusals = {
    "the select list reads the joined table" => "SELECT p.id, u.name FROM public.posts p JOIN public.users u " \
                                                "ON p.user_id = u.id",
    "the select list holds its star" => "SELECT p.id, u.* FROM public.posts p JOIN public.users u ON p.user_id = u.id",
    "the select list holds a bare star" => "SELECT * FROM public.posts p JOIN public.users u ON p.user_id = u.id",
    "the query reads its whole row" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                                       "WHERE u IS NOT NULL",
    "a bare column only it has is read" => "SELECT p.id, name FROM public.posts p JOIN public.users u " \
                                           "ON p.user_id = u.id",
    "the ON holds another condition on it" => "SELECT p.id FROM public.posts p JOIN public.users u " \
                                              "ON p.user_id = u.id AND u.name = 'ann'",
    "the WHERE filters it" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                              "WHERE u.org = 5",
    "the ORDER BY reads it" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                               "ORDER BY u.name",
    "the GROUP BY reads it" => "SELECT count(*) FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                               "GROUP BY u.id",
    "a window reads it" => "SELECT p.id, row_number() OVER (PARTITION BY u.org) FROM public.posts p " \
                           "JOIN public.users u ON p.user_id = u.id",
    "a subquery reads it" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                             "WHERE EXISTS (SELECT 1 FROM public.orphans o WHERE o.user_id = u.id)",
    "the join is on a nullable column" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.editor_id = u.id",
    "there's no foreign key" => "SELECT o.id FROM public.orphans o JOIN public.users u ON o.user_id = u.id",
    "the foreign key is NOT VALID" => "SELECT c.id FROM public.comments c JOIN public.users u ON c.user_id = u.id",
    "the foreign key is deferrable" => "SELECT d.id FROM public.deferred d JOIN public.users u ON d.user_id = u.id",
    "the join covers only some of a foreign key's columns" => "SELECT p.id FROM public.posts p JOIN public.users u " \
                                                              "ON p.org = u.org",
    "the join pairs the wrong columns" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.org",
    "the columns' types differ" => "SELECT n.id FROM public.narrow n JOIN public.wide w ON n.wide_id = w.id",
    "it's a LEFT JOIN" => "SELECT p.id FROM public.posts p LEFT JOIN public.users u ON p.user_id = u.id",
    "the join has an alias" => "SELECT j.id FROM (public.posts p JOIN public.users u ON p.user_id = u.id) j",
    "the join is USING" => "SELECT p.id FROM public.posts p JOIN public.users u USING (id)",
    "another join is USING" => "SELECT p.id FROM (public.posts p JOIN public.users u ON p.user_id = u.id) " \
                               "JOIN public.orphans o USING (id)",
    "a join inside another is USING" => "SELECT p.id FROM public.orphans o JOIN (public.posts p JOIN public.users u " \
                                        "ON p.user_id = u.id JOIN public.deferred d USING (id)) ON o.id = p.id",
    "the comparison isn't a plain =" => "SELECT p.id FROM public.posts p JOIN public.users u " \
                                        "ON p.user_id OPERATOR(pg_catalog.=) u.id",
    "a column is cast" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id::bigint = u.id",
    "the joining table is on an outer join's nullable side" =>
      "SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id JOIN public.users u " \
      "ON p.user_id = u.id",
    "a comma join's joining table is on an outer join's nullable side" =>
      "SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id, public.users u " \
      "WHERE p.user_id = u.id",
    "a comma join's equality is under an OR" => "SELECT p.id FROM public.posts p, public.users u " \
                                                "WHERE p.user_id = u.id OR p.id = 1",
    "the query locks rows" => "SELECT p.id FROM public.posts p JOIN public.users u ON p.user_id = u.id " \
                              "FOR UPDATE OF u",
    "the joined table is read with ONLY" => "SELECT p.id FROM public.posts p JOIN ONLY public.users u " \
                                            "ON p.user_id = u.id"
  }

  refusals.each do |why, sql|
    it "doesn't fire when #{why}" do
      expect(rewritten(sql)).to eq([])
    end
  end

  it "would be wrong on a nullable column: the join drops the row whose column is NULL" do
    sql = "SELECT p.id FROM public.posts p JOIN public.users u ON p.editor_id = u.id"

    expect(rows(sql)).not_to eq(rows("SELECT p.id FROM public.posts p"))
  end

  it "would be wrong on a NOT VALID foreign key: the join drops the orphan" do
    sql = "SELECT c.id FROM public.comments c JOIN public.users u ON c.user_id = u.id"

    expect(rows(sql)).to eq([["1"]])
    expect(rows("SELECT c.id FROM public.comments c")).to eq([["1"], ["2"]])
  end

  it "would be wrong on a joining table an outer join can fill with NULL" do
    sql = "SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id JOIN public.users u " \
          "ON p.user_id = u.id"

    expect(rows(sql)).to eq([])
    expect(rows("SELECT o.id FROM public.orphans o LEFT JOIN public.posts p ON p.id = o.id")).to eq([["1"], ["2"]])
  end

  context "when the tables aren't plain" do
    it "doesn't fire on a partitioned joined table" do
      conn.exec(<<~SQL)
        CREATE TABLE public.parts (id int PRIMARY KEY) PARTITION BY RANGE (id);
        CREATE TABLE public.parts_1 PARTITION OF public.parts FOR VALUES FROM (0) TO (100);
        CREATE TABLE public.uses (id int PRIMARY KEY, part_id int NOT NULL REFERENCES public.parts);
      SQL

      expect(rewritten("SELECT s.id FROM public.uses s JOIN public.parts t ON s.part_id = t.id")).to eq([])
    end

    it "doesn't fire on a partitioned joined table that has no partitions yet" do
      conn.exec(<<~SQL)
        CREATE TABLE public.parts (id int PRIMARY KEY) PARTITION BY RANGE (id);
        CREATE TABLE public.uses (id int PRIMARY KEY, part_id int NOT NULL REFERENCES public.parts);
      SQL

      expect(rewritten("SELECT s.id FROM public.uses s JOIN public.parts t ON s.part_id = t.id")).to eq([])
    end

    it "doesn't fire on a joined table with inheritance children" do
      conn.exec(<<~SQL)
        CREATE TABLE public.base (id int PRIMARY KEY);
        CREATE TABLE public.kid () INHERITS (public.base);
        CREATE TABLE public.uses (id int PRIMARY KEY, base_id int NOT NULL REFERENCES public.base);
      SQL

      expect(rewritten("SELECT s.id FROM public.uses s JOIN public.base t ON s.base_id = t.id")).to eq([])
    end

    it "doesn't fire on a joining table with inheritance children, whose rows the foreign key doesn't cover" do
      conn.exec(<<~SQL)
        CREATE TABLE public.uses (id int PRIMARY KEY, user_id int NOT NULL REFERENCES public.users);
        CREATE TABLE public.kid () INHERITS (public.uses);
        INSERT INTO public.kid VALUES (1, 99);
      SQL
      sql = "SELECT s.id FROM public.uses s JOIN public.users t ON s.user_id = t.id"

      expect(rows(sql)).to eq([])
      expect(rewritten(sql)).to eq([])
    end

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

      expect(rewritten("SELECT l.id FROM public.loose l JOIN public.users u ON l.user_id = u.id")).to eq([])
    end

    it "fires on text columns with a deterministic collation" do
      conn.exec(<<~SQL)
        CREATE TABLE public.codes (code text PRIMARY KEY);
        CREATE TABLE public.coded (id int PRIMARY KEY, code text COLLATE "C" NOT NULL REFERENCES public.codes);
      SQL

      expect(rewritten("SELECT d.id FROM public.coded d JOIN public.codes c ON d.code = c.code"))
        .to eq(["SELECT d.id FROM public.coded d"])
    end

    it "doesn't fire on columns with a nondeterministic collation" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        CREATE TABLE public.tags (name text COLLATE public.ci PRIMARY KEY);
        CREATE TABLE public.taggings (id int PRIMARY KEY, tag text COLLATE public.ci NOT NULL REFERENCES public.tags);
      SQL

      expect(rewritten("SELECT g.id FROM public.taggings g JOIN public.tags t ON g.tag = t.name")).to eq([])
    end

    it "doesn't fire on a varchar column whose key is text, since it takes only columns of one type" do
      conn.exec(<<~SQL)
        CREATE TABLE public.codes (code text PRIMARY KEY);
        CREATE TABLE public.coded (id int PRIMARY KEY, code varchar NOT NULL REFERENCES public.codes);
      SQL

      expect(rewritten("SELECT d.id FROM public.coded d JOIN public.codes c ON d.code = c.code")).to eq([])
    end

    it "doesn't fire on a joined table that's a view" do
      conn.exec("CREATE VIEW public.people AS SELECT * FROM public.users")

      expect(rewritten("SELECT p.id FROM public.posts p JOIN public.people u ON p.user_id = u.id")).to eq([])
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
      sql = "SELECT p.id FROM app.posts p JOIN app.users u ON p.user_id = u.id"

      expect(rewritten(sql)).to eq(["SELECT p.id FROM app.posts p"])
      expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions.first).to include(
        "table" => "app.posts", "references_table" => "app.users"
      )
    end

    it "doesn't fire across schemas when the foreign key points at the other one's table" do
      sql = "SELECT p.id FROM app.posts p JOIN public.users u ON p.user_id = u.id"

      expect(rewritten(sql)).to eq([])
    end
  end
end
