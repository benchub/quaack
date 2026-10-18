# frozen_string_literal: true

require "json"
require "pg_query"
require "tmpdir"
require "quaack/enclave/assumption_check"
require "quaack/enclave/deparse"
require "quaack/enclave/literal_set"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/store"
require "quaack/enclave/table_name"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' union_to_union_all, on a real server: what it
# writes, that its output returns the rows its input does, and that it fires
# only when each arm selects a unique, not-null key of its one table and a
# tag placeholder that, as the UNION compares it, differs from every other
# arm's.
RSpec.describe Quaack::Enclave::RewriteRules::UnionToUnionAll do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Post 1 and comment 1 share an id and a created_at, and so do post 2 and
  # comment 2, so a UNION that compares only those merges them. Post 1's
  # tags repeat an element, and post 1 has two comments. Two drafts have a
  # NULL id and one created_at, and events 1 and archived 1 (with its legacy
  # child's copy) repeat a row, so a UNION over those merges rows of one arm.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.posts (id bigint PRIMARY KEY, group_id bigint NOT NULL, title text, tags int[],
                                 created_at timestamptz NOT NULL);
      CREATE TABLE public.comments (id bigint PRIMARY KEY, post_id bigint NOT NULL, group_id bigint NOT NULL,
                                    body text, created_at timestamptz NOT NULL);
      CREATE TABLE public.likes (id bigint PRIMARY KEY, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.shares (id bigint PRIMARY KEY, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.memberships (user_id bigint, group_id bigint, role text, PRIMARY KEY (user_id, group_id));
      CREATE TABLE public.short_codes (code varchar(10) PRIMARY KEY);
      CREATE TABLE public.long_codes (code varchar(20) PRIMARY KEY);
      CREATE TABLE public.small_posts (id int PRIMARY KEY, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.drafts (id bigint UNIQUE, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.notes (id bigint UNIQUE NULLS NOT DISTINCT, group_id bigint NOT NULL);
      CREATE TABLE public.events (id bigint, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.hosts (addr inet PRIMARY KEY, group_id bigint NOT NULL);
      CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.handles (name text COLLATE public.loose PRIMARY KEY, group_id bigint NOT NULL);
      CREATE TABLE public.archived (id bigint PRIMARY KEY, group_id bigint NOT NULL, created_at timestamptz NOT NULL);
      CREATE TABLE public.archived_old () INHERITS (public.archived);
      INSERT INTO public.posts VALUES
        (1, 1, 'a', '{1,1}', '2026-01-01 01:00+00'), (2, 1, 'b', '{2}', '2026-01-01 02:00+00'),
        (3, 2, 'c', '{3}', '2026-01-01 03:00+00'), (4, 1, 'a', '{4}', '2026-01-01 04:00+00');
      INSERT INTO public.comments VALUES
        (1, 1, 1, 'x', '2026-01-01 01:00+00'), (2, 1, 1, 'y', '2026-01-01 02:00+00'),
        (5, 3, 2, 'z', '2026-01-01 05:00+00'), (6, 4, 1, 'w', '2026-01-01 06:00+00');
      INSERT INTO public.likes VALUES (1, 1, '2026-01-01 07:00+00'), (7, 2, '2026-01-01 08:00+00');
      INSERT INTO public.shares VALUES (1, 1, '2026-01-01 09:00+00'), (2, 1, '2026-01-01 10:00+00');
      INSERT INTO public.memberships VALUES (1, 1, 'admin'), (1, 2, 'member'), (2, 1, 'member');
      INSERT INTO public.short_codes VALUES ('a'), ('b');
      INSERT INTO public.long_codes VALUES ('a'), ('c');
      INSERT INTO public.small_posts VALUES (1, 1, '2026-01-01 01:00+00'), (2, 1, '2026-01-01 02:00+00');
      INSERT INTO public.drafts VALUES (NULL, 1, '2026-01-01 01:00+00'), (NULL, 1, '2026-01-01 01:00+00'),
        (3, 1, '2026-01-01 03:00+00');
      INSERT INTO public.notes VALUES (NULL, 1), (3, 1);
      INSERT INTO public.events VALUES (1, 1, '2026-01-01 01:00+00'), (1, 1, '2026-01-01 01:00+00');
      INSERT INTO public.hosts VALUES ('10.0.0.1', 1), ('10.0.0.2', 1);
      INSERT INTO public.handles VALUES ('Ann', 1), ('Bob', 1);
      INSERT INTO public.archived VALUES (1, 1, '2026-01-01 01:00+00');
      INSERT INTO public.archived_old VALUES (1, 1, '2026-01-01 01:00+00');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  # The rule's rewrites of sql, redacted as intake redacts it, with the
  # literal oracle for its literals.
  def rewrites(sql)
    redacted = redacted(sql)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)
    rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals)
  end

  def rewritten(sql) = rewrites(sql).map { Quaack::Enclave::Deparse.faithfully(it.tree) }

  def assumptions(sql) = rewrites(sql).map(&:assumptions)

  # The rows of sql, written with placeholders, bound to map's literals.
  def bound_rows(sql, map)
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

  def rows(sql) = conn.exec(sql).values.sort_by(&:to_s)

  # The rule rewrites sql to exactly expected, which returns sql's rows,
  # and they aren't empty.
  def expect_rewrite(sql, expected)
    expect(rewritten(sql)).to eq([expected])
    map = redacted(sql).placeholder_map
    want = rows(sql)
    expect(want).not_to be_empty
    expect(bound_rows(expected, map)).to eq(want)
  end

  # The rule leaves sql alone, though it runs.
  def expect_refused(sql)
    expect(conn.exec(sql).ntuples).to be_positive, sql
    expect(rewritten(sql)).to eq([]), sql
  end

  # The rule leaves sql alone, and with each UNION made UNION ALL by hand,
  # it would return other rows.
  def expect_refused_and_wrong(sql)
    expect_refused(sql)
    expect(rows(sql.gsub(" UNION ", " UNION ALL "))).not_to eq(rows(sql)), sql
  end

  feed = "SELECT 'post' AS kind, posts.id, posts.created_at FROM public.posts WHERE posts.group_id = 1 " \
         "UNION SELECT 'comment', comments.id, comments.created_at FROM public.comments WHERE comments.group_id = 1"
  let(:feed) { feed }

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["union_to_union_all",
       "A UNION becomes UNION ALL when each arm selects a unique, not-null key of its one table and a tag " \
       "placeholder that differs from every other arm's, so no two of its rows can be equal."]
    )
  end

  it "makes an activity feed's UNION a UNION ALL, and leaves the rest of the query as it was" do
    expect_rewrite(
      feed,
      "SELECT $1 AS kind, posts.id, posts.created_at FROM public.posts WHERE posts.group_id = $2 " \
      "UNION ALL SELECT $3, comments.id, comments.created_at FROM public.comments WHERE comments.group_id = $4"
    )
    expect(rows(feed).map { it.first(2) }).to eq(
      [%w[comment 1], %w[comment 2], %w[comment 6], %w[post 1], %w[post 2], %w[post 4]]
    )
  end

  it "states each arm's key unique and not null" do
    expect(assumptions(feed)).to eq(
      [[{ "kind" => "unique", "table" => "public.posts", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "id" },
        { "kind" => "unique", "table" => "public.comments", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.comments", "column" => "id" }]]
    )
  end

  it "states only assumptions the catalog proves, so assumption-check accepts them" do
    stated = assumptions(feed).flatten(1)

    expect(stated.map { Quaack::Enclave::AssumptionCheck.met?(it, conn) }).to eq([true] * 4)
  end

  it "doesn't change the parse it was given" do
    redacted = redacted(feed)
    parse = PgQuery.parse(redacted.sql)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)

    expect(parse.tree).to eq(before)
  end

  it "gives nothing without the literal oracle" do
    expect(rule.rewrites(PgQuery.parse(redacted(feed).sql), catalog, nil)).to eq([])
  end

  it "takes a Rails-style feed of three arms, quoted and unqualified columns, with ORDER BY and LIMIT" do
    expect_rewrite(
      %(SELECT 'Post' AS item_type, "posts"."id" AS item_id, "posts"."created_at" FROM "public"."posts" \
        UNION SELECT 'Comment', "comments"."id", "comments"."created_at" FROM "public"."comments" \
        UNION SELECT 'Like', id, created_at FROM public.likes ORDER BY created_at DESC LIMIT 20).squeeze(" "),
      "(SELECT $1 AS item_type, posts.id AS item_id, posts.created_at FROM public.posts " \
      "UNION ALL SELECT $2, comments.id, comments.created_at FROM public.comments) " \
      "UNION ALL SELECT $3, id, created_at FROM public.likes ORDER BY created_at DESC LIMIT $4"
    )
  end

  it "takes a UNION in a derived table that the outer query filters, and one in a CTE" do
    expect_rewrite(
      "SELECT feed.kind, feed.id FROM (SELECT 'post' AS kind, posts.id, posts.group_id FROM public.posts " \
      "UNION SELECT 'comment', comments.id, comments.group_id FROM public.comments) feed WHERE feed.group_id = 1",
      "SELECT feed.kind, feed.id FROM (SELECT $1 AS kind, posts.id, posts.group_id FROM public.posts " \
      "UNION ALL SELECT $2, comments.id, comments.group_id FROM public.comments) feed WHERE feed.group_id = $3"
    )
    expect_rewrite(
      "WITH feed AS (SELECT 'post' AS kind, posts.id FROM public.posts " \
      "UNION SELECT 'comment', comments.id FROM public.comments) SELECT feed.kind, feed.id FROM feed",
      "WITH feed AS (SELECT $1 AS kind, posts.id FROM public.posts " \
      "UNION ALL SELECT $2, comments.id FROM public.comments) SELECT feed.kind, feed.id FROM feed"
    )
  end

  it "takes a tag in any position, cast or not, of any type the arms agree on" do
    expect_rewrite(
      "SELECT posts.id, 'post'::text AS kind FROM public.posts UNION SELECT comments.id, 'comment'::text " \
      "FROM public.comments",
      "SELECT posts.id, $1::text AS kind FROM public.posts UNION ALL SELECT comments.id, $2::text " \
      "FROM public.comments"
    )
    expect_rewrite(
      "SELECT 1 AS kind, posts.id FROM public.posts UNION SELECT 2, comments.id FROM public.comments",
      "SELECT $1 AS kind, posts.id FROM public.posts UNION ALL SELECT $2, comments.id FROM public.comments"
    )
  end

  it "takes arms with their own ORDER BY and LIMIT" do
    expect_rewrite(
      "(SELECT 'post' AS kind, posts.id, posts.created_at FROM public.posts ORDER BY posts.created_at DESC " \
      "LIMIT 2) UNION (SELECT 'comment', comments.id, comments.created_at FROM public.comments " \
      "ORDER BY comments.created_at DESC LIMIT 2)",
      "(SELECT $1 AS kind, posts.id, posts.created_at FROM public.posts ORDER BY posts.created_at DESC " \
      "LIMIT $2) UNION ALL (SELECT $3, comments.id, comments.created_at FROM public.comments " \
      "ORDER BY comments.created_at DESC LIMIT $4)"
    )
  end

  it "takes two arms over one table, whose tags keep a row both arms select apart" do
    sql = "SELECT 'mine' AS reason, posts.id FROM public.posts WHERE posts.group_id = 1 " \
          "UNION SELECT 'titled', posts.id FROM public.posts WHERE posts.title = 'a'"

    expect_rewrite(
      sql,
      "SELECT $1 AS reason, posts.id FROM public.posts WHERE posts.group_id = $2 " \
      "UNION ALL SELECT $3, posts.id FROM public.posts WHERE posts.title = $4"
    )
    expect(rows(sql)).to eq([%w[mine 1], %w[mine 2], %w[mine 4], %w[titled 1], %w[titled 4]])
  end

  it "takes a key of several columns, and states each of them not null" do
    sql = "SELECT 'member' AS kind, memberships.user_id, memberships.group_id FROM public.memberships " \
          "UNION SELECT 'post', posts.id, posts.group_id FROM public.posts"

    expect_rewrite(
      sql,
      "SELECT $1 AS kind, memberships.user_id, memberships.group_id FROM public.memberships " \
      "UNION ALL SELECT $2, posts.id, posts.group_id FROM public.posts"
    )
    expect(assumptions(sql)).to eq(
      [[{ "kind" => "unique", "table" => "public.memberships", "columns" => %w[user_id group_id] },
        { "kind" => "not_null", "table" => "public.memberships", "column" => "user_id" },
        { "kind" => "not_null", "table" => "public.memberships", "column" => "group_id" },
        { "kind" => "unique", "table" => "public.posts", "columns" => ["id"] },
        { "kind" => "not_null", "table" => "public.posts", "column" => "id" }]]
    )
  end

  it "takes key columns of one type with different typmods, whose values the UNION doesn't change" do
    expect_rewrite(
      "SELECT 'short' AS kind, short_codes.code FROM public.short_codes " \
      "UNION SELECT 'long', long_codes.code FROM public.long_codes",
      "SELECT $1 AS kind, short_codes.code FROM public.short_codes " \
      "UNION ALL SELECT $2, long_codes.code FROM public.long_codes"
    )
  end

  it "takes a star, which stands for every column of the arm's table" do
    expect_rewrite(
      "SELECT 'one' AS kind, posts.* FROM public.posts WHERE posts.group_id = 1 " \
      "UNION SELECT 'two', * FROM public.posts WHERE posts.group_id = 2",
      "SELECT $1 AS kind, posts.* FROM public.posts WHERE posts.group_id = $2 " \
      "UNION ALL SELECT $3, * FROM public.posts WHERE posts.group_id = $4"
    )
  end

  it "gives one rewrite for each UNION it can take, each made from the original" do
    sql = "SELECT f.kind, g.kind FROM (SELECT 'post' AS kind, posts.id FROM public.posts " \
          "UNION SELECT 'comment', comments.id FROM public.comments) f " \
          "JOIN (SELECT 'post' AS kind, posts.id FROM public.posts " \
          "UNION SELECT 'like', likes.id FROM public.likes) g ON g.id = f.id"
    first = "(SELECT $1 AS kind, posts.id FROM public.posts UNION ALL SELECT $2, comments.id FROM public.comments) f"
    second = "(SELECT $3 AS kind, posts.id FROM public.posts UNION ALL SELECT $4, likes.id FROM public.likes) g"

    expect(rewritten(sql)).to eq(
      ["SELECT f.kind, g.kind FROM #{first} JOIN (SELECT $3 AS kind, posts.id FROM public.posts " \
       "UNION SELECT $4, likes.id FROM public.likes) g ON g.id = f.id",
       "SELECT f.kind, g.kind FROM (SELECT $1 AS kind, posts.id FROM public.posts " \
       "UNION SELECT $2, comments.id FROM public.comments) f JOIN #{second} ON g.id = f.id"]
    )
  end

  describe "the tags" do
    it "refuses two tags that hold the same literal" do
      expect_refused_and_wrong(
        "SELECT 'x' AS kind, posts.id, posts.created_at FROM public.posts " \
        "UNION SELECT 'x', comments.id, comments.created_at FROM public.comments"
      )
    end

    it "compares the tags as the UNION does, in its column's type" do
      expect_refused_and_wrong(
        "SELECT 1 AS kind, posts.id, posts.created_at FROM public.posts " \
        "UNION SELECT 1.0, comments.id, comments.created_at FROM public.comments"
      )
      expect_refused_and_wrong(
        "SELECT 'ab'::varchar(1) AS kind, posts.id, posts.created_at FROM public.posts " \
        "UNION SELECT 'ac'::varchar(1), comments.id, comments.created_at FROM public.comments"
      )
      expect(rewritten("SELECT 1 AS kind, posts.id FROM public.posts " \
                       "UNION SELECT 2.0, comments.id FROM public.comments").size).to eq(1)
    end

    it "refuses three arms when any two of their tags match" do
      expect_refused_and_wrong(
        "SELECT 'post' AS kind, posts.id, posts.created_at FROM public.posts " \
        "UNION SELECT 'like', likes.id, likes.created_at FROM public.likes " \
        "UNION SELECT 'post', comments.id, comments.created_at FROM public.comments"
      )
    end

    it "refuses a UNION with no tag, such as two arms over one table that can return one row twice" do
      expect_refused_and_wrong(
        "SELECT posts.id, posts.created_at FROM public.posts UNION " \
        "SELECT comments.id, comments.created_at FROM public.comments"
      )
      expect_refused_and_wrong(
        "SELECT posts.id, posts.created_at FROM public.posts WHERE posts.group_id = 1 UNION " \
        "SELECT posts.id, posts.created_at FROM public.posts WHERE posts.title = 'a'"
      )
    end

    it "refuses a tag that isn't a placeholder in every arm" do
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION SELECT comments.body, comments.id FROM public.comments"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.title, posts.id FROM public.posts " \
        "UNION SELECT comments.body, 'comment', comments.id FROM public.comments"
      )
    end

    it "refuses a tag placeholder the query uses anywhere else" do
      map = { "$1" => { "value" => "a", "type" => "unknown" }, "$2" => { "value" => "b", "type" => "unknown" } }
      literals = Quaack::Enclave::RewriteRules::Literals.new(conn, map)
      shared = "SELECT $1 AS kind, posts.id FROM public.posts WHERE posts.title = $1 " \
               "UNION SELECT $2, comments.id FROM public.comments"
      apart = "SELECT $1 AS kind, posts.id FROM public.posts WHERE posts.title = 'a' " \
              "UNION SELECT $2, comments.id FROM public.comments"

      expect(rule.rewrites(PgQuery.parse(shared), catalog, literals)).to eq([])
      expect(rule.rewrites(PgQuery.parse(apart), catalog, literals).size).to eq(1)
    end

    # DESIGN.md's literals: result-comparison runs the rewrite with every
    # literal set, so the tags must hold their slow literals in all of them.
    it "keeps every tag at its slow literal in every literal set, while a column predicate's placeholder moves" do
      Dir.mktmpdir("quaack-union-to-union-all") do |dir|
        store = Quaack::Enclave::Store.create(base: File.join(dir, "runs"))
        conn.exec(<<~SQL)
          INSERT INTO public.posts SELECT i, 1 + i % 3, 'p' || i, '{}', '2026-02-01 00:00+00'::timestamptz + i * interval '1 minute'
          FROM generate_series(10, 400) AS i;
          INSERT INTO public.comments SELECT i, 1, 1 + i % 5, 'c' || i, '2026-03-01 00:00+00'::timestamptz + i * interval '1 minute'
          FROM generate_series(10, 400) AS i;
          ANALYZE public.posts, public.comments;
        SQL
        query = "SELECT 'post' AS kind, posts.id FROM public.posts WHERE posts.group_id = 3 " \
                "UNION SELECT 'comment'::text, comments.id FROM public.comments WHERE comments.group_id = 4 " \
                "ORDER BY 2 LIMIT 20"
        explain = JSON.parse(conn.exec("EXPLAIN (ANALYZE, VERBOSE, BUFFERS, FORMAT JSON) #{query}").getvalue(0, 0))
        redacted = Quaack::Enclave::Redaction.redact(PgQuery.parse(query), explain)
        redacted.store(store)
        relations = %w[posts comments].map { Quaack::Enclave::TableName.new(schema: "public", name: it) }
        Quaack::Enclave::PlannerStatistics.run(store:, relations:, connection: conn)
        result = Quaack::Enclave::LiteralSet.run(store:, sql: redacted.query.sql)
        values = result.sets.transform_values { |set| set.transform_values { it["value"] } }

        expect(redacted.query.sql)
          .to start_with("SELECT $1 AS kind, posts.id FROM public.posts WHERE posts.group_id = $2 ")
        expect(rewritten(query).size).to eq(1)
        expect(values.values.map { it.values_at("$1", "$3") }).to eq([%w[post comment]] * 3)
        expect(result.fallbacks.values.map { it.values_at("$1", "$3") }).to eq([%w[unsupported_shape] * 2] * 2)
        expect(values.values.map { it["$2"] }.uniq.size).to be > 1
      end
    end
  end

  describe "the set operations" do
    it "refuses a tree with a UNION ALL or another set operation in it" do
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION ALL SELECT 'comment', comments.id " \
        "FROM public.comments UNION SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION SELECT 'comment', comments.id " \
        "FROM public.comments UNION ALL SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "(SELECT 'post' AS kind, posts.id FROM public.posts UNION SELECT 'comment', comments.id " \
        "FROM public.comments) EXCEPT SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts INTERSECT SELECT 'post', comments.id FROM public.comments"
      )
    end

    it "leaves a UNION ALL as it is" do
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION ALL SELECT 'comment', comments.id " \
        "FROM public.comments"
      )
    end
  end

  describe "the keys" do
    it "refuses an arm that doesn't select a key of its table" do
      expect_refused_and_wrong(
        "SELECT 'post' AS kind, posts.group_id FROM public.posts UNION SELECT 'comment', comments.group_id " \
        "FROM public.comments"
      )
    end

    it "refuses a unique key that can be NULL, even under NULLS NOT DISTINCT" do
      expect_refused_and_wrong(
        "SELECT 'draft' AS kind, drafts.id, drafts.created_at FROM public.drafts " \
        "UNION SELECT 'post', posts.id, posts.created_at FROM public.posts"
      )
      expect_refused(
        "SELECT 'note' AS kind, notes.id FROM public.notes UNION SELECT 'post', posts.id FROM public.posts"
      )
    end

    it "refuses an outer query's column, even one written with a key's name, and an outer query's star" do
      expect_refused_and_wrong(
        "SELECT posts.id, (SELECT count(*) FROM (SELECT 'comment' AS kind, posts.id FROM public.comments " \
        "WHERE comments.post_id = posts.id UNION SELECT 'like', likes.id FROM public.likes " \
        "WHERE likes.id = posts.id) feed) AS n FROM public.posts"
      )
      expect_refused_and_wrong(
        "SELECT likes.id, (SELECT count(*) FROM (SELECT 'share' AS kind, likes.* FROM public.shares " \
        "WHERE shares.group_id = likes.group_id UNION SELECT 'like', l.* FROM public.likes l) feed) AS n " \
        "FROM public.likes"
      )
    end

    it "refuses a table with no unique index, and one with legacy children" do
      expect_refused_and_wrong(
        "SELECT 'event' AS kind, events.id, events.created_at FROM public.events " \
        "UNION SELECT 'post', posts.id, posts.created_at FROM public.posts"
      )
      expect_refused_and_wrong(
        "SELECT 'archived' AS kind, archived.id, archived.created_at FROM public.archived " \
        "UNION SELECT 'post', posts.id, posts.created_at FROM public.posts"
      )
    end

    it "refuses a key the select list reads only through an expression or a cast" do
      expect_refused(
        "SELECT 'post' AS kind, posts.id + 0 AS id FROM public.posts UNION SELECT 'comment', comments.id " \
        "FROM public.comments"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id::int AS id FROM public.posts UNION SELECT 'comment', comments.id::int " \
        "FROM public.comments"
      )
    end

    it "refuses a key whose position holds another type in another arm" do
      expect_refused(
        "SELECT 'small' AS kind, small_posts.id FROM public.small_posts UNION SELECT 'comment', comments.id " \
        "FROM public.comments"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION SELECT 'comment', 7::bigint FROM public.comments"
      )
    end

    it "refuses a key of a type the catalog doesn't mark comparable, or with a nondeterministic collation" do
      expect_refused(
        "SELECT 'host' AS kind, hosts.addr FROM public.hosts UNION SELECT 'other', hosts.addr FROM public.hosts"
      )
      expect_refused(
        "SELECT 'handle' AS kind, handles.name FROM public.handles " \
        "UNION SELECT 'other', handles.name FROM public.handles"
      )
    end
  end

  describe "the arms" do
    it "refuses an arm that joins, or reads a subquery, a CTE, or VALUES" do
      expect_refused_and_wrong(
        "SELECT 'post' AS kind, posts.id FROM public.posts JOIN public.comments ON comments.post_id = posts.id " \
        "UNION SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "SELECT 'post' AS kind, p.id FROM (SELECT posts.id FROM public.posts) p " \
        "UNION SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "WITH p AS (SELECT posts.id FROM public.posts) SELECT 'post' AS kind, p.id FROM p " \
        "UNION SELECT 'like', likes.id FROM public.likes"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM public.posts UNION VALUES ('like', 1::bigint)"
      )
    end

    it "refuses an arm that calls a set-returning function, in its select list or its ORDER BY" do
      expect_refused_and_wrong(
        "SELECT 'post' AS kind, posts.id, unnest(posts.tags) AS tag FROM public.posts " \
        "UNION SELECT 'like', likes.id, 0 FROM public.likes"
      )
      expect_refused_and_wrong(
        "(SELECT 'post' AS kind, posts.id FROM public.posts ORDER BY unnest(posts.tags)) " \
        "UNION SELECT 'like', likes.id FROM public.likes"
      )
    end

    it "refuses an arm with DISTINCT, GROUP BY, an aggregate, or a window function" do
      tail = "UNION SELECT 'like', likes.id FROM public.likes"

      expect_refused("SELECT DISTINCT 'post' AS kind, posts.id FROM public.posts #{tail}")
      expect_refused("SELECT 'post' AS kind, posts.id FROM public.posts GROUP BY posts.id #{tail}")
      expect_refused(
        "SELECT 'post' AS kind, posts.id, count(*) OVER () AS n FROM public.posts " \
        "UNION SELECT 'like', likes.id, 1 FROM public.likes"
      )
      expect_refused(
        "SELECT 'post' AS kind, posts.id, (SELECT count(*) FROM public.comments c WHERE c.post_id = posts.id) AS n " \
        "FROM public.posts UNION SELECT 'like', likes.id, 1 FROM public.likes"
      )
    end

    it "gives nothing for arms of different widths, which Postgres refuses" do
      map = { "$1" => { "value" => "a", "type" => "unknown" }, "$2" => { "value" => "b", "type" => "unknown" } }
      literals = Quaack::Enclave::RewriteRules::Literals.new(conn, map)
      sql = "SELECT $1 AS kind, posts.id FROM public.posts UNION SELECT $2 FROM public.comments"

      expect(rule.rewrites(PgQuery.parse(sql), catalog, literals)).to eq([])
    end

    it "refuses a table read with ONLY" do
      expect_refused(
        "SELECT 'post' AS kind, posts.id FROM ONLY public.posts UNION SELECT 'like', likes.id FROM public.likes"
      )
    end
  end
end
