# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# vacuity-guard over a corpus of realistic query shapes (20261010-27), the
# ordinary SELECTs apps and ORMs generate. A safety net: each shape runs
# through the real Scenarios::Builder and VacuityGuard, and its untested set
# must equal its allow-list exactly. Each allowed atom carries why it's
# allowed: truly redundant, or provably untestable on any fixture.
#
# PENDING names the shapes that today leave a non-redundant atom untested.
# Each pins today's untested set exactly, so a fix (or a regression that
# changes it) turns it red; then move the shape to SHAPES. Each names a
# guess at the cause, which isn't confirmed.
#
# To add a shape, add one entry. To see what each shape leaves untested,
# set QUAACK_CORPUS_DUMP to a file path; every example appends a JSON line.
module VacuityCorpus # rubocop:disable Metrics/ModuleLength -- a data table; one entry per shape
  SCHEMA = <<~SQL
    CREATE SCHEMA fx;
    CREATE TYPE fx.role AS ENUM ('student', 'teacher', 'admin');
    CREATE TABLE fx.users (id bigint PRIMARY KEY, email text NOT NULL UNIQUE, name text NOT NULL,
      role fx.role NOT NULL DEFAULT 'student', active boolean NOT NULL DEFAULT true,
      manager_id bigint REFERENCES fx.users, birthday date, deleted_at timestamp,
      settings jsonb NOT NULL DEFAULT '{}', created_at timestamp NOT NULL);
    CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
      title text NOT NULL, body text, published boolean NOT NULL DEFAULT false, score integer NOT NULL DEFAULT 0,
      labels text[] NOT NULL DEFAULT '{}', published_on date, created_at timestamp NOT NULL);
    CREATE TABLE fx.comments (id bigint PRIMARY KEY, post_id bigint NOT NULL REFERENCES fx.posts,
      user_id bigint REFERENCES fx.users, body text NOT NULL, workflow_state text NOT NULL,
      created_at timestamp NOT NULL);
    CREATE TABLE fx.tags (id bigint PRIMARY KEY, name text NOT NULL UNIQUE);
    CREATE TABLE fx.post_tags (post_id bigint NOT NULL REFERENCES fx.posts, tag_id bigint NOT NULL REFERENCES fx.tags,
      PRIMARY KEY (post_id, tag_id));
    CREATE TABLE fx.memberships (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
      group_name text NOT NULL, kind text NOT NULL, UNIQUE (user_id, group_name));
    CREATE TABLE fx.attachments (id bigint PRIMARY KEY, attachable_type text NOT NULL, attachable_id bigint NOT NULL,
      filename text NOT NULL, size integer NOT NULL);
  SQL

  # Each entry: name, sql, and allowed (atom shape => reason).
  SHAPES = [
    # Single-table filters, one per type.
    { name: "text equality", sql: "SELECT * FROM fx.users WHERE fx.users.name = 'ann'", allowed: {} },
    { name: "unique text equality", sql: "SELECT fx.users.id FROM fx.users WHERE fx.users.email = 'a@b'", allowed: {} },
    { name: "integer range", sql: "SELECT * FROM fx.posts WHERE fx.posts.score > 10", allowed: {} },
    { name: "integer <=", sql: "SELECT * FROM fx.posts WHERE fx.posts.score <= 3", allowed: {} },
    { name: "integer <>", sql: "SELECT * FROM fx.posts WHERE fx.posts.score <> 0", allowed: {} },
    { name: "BETWEEN on integer", sql: "SELECT * FROM fx.posts WHERE fx.posts.score BETWEEN 1 AND 9", allowed: {} },
    { name: "BETWEEN on date",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.published_on BETWEEN '2026-01-01' AND '2026-02-01'", allowed: {} },
    { name: "timestamp >=", sql: "SELECT * FROM fx.posts WHERE fx.posts.created_at >= '2026-03-01'", allowed: {} },
    { name: "date < on nullable", sql: "SELECT * FROM fx.users WHERE fx.users.birthday < '2000-01-01'", allowed: {} },
    { name: "boolean = true", sql: "SELECT * FROM fx.posts WHERE fx.posts.published = true", allowed: {} },
    { name: "bare boolean", sql: "SELECT * FROM fx.posts WHERE fx.posts.published", allowed: {} },
    { name: "NOT boolean", sql: "SELECT * FROM fx.posts WHERE NOT fx.posts.published", allowed: {} },
    { name: "boolean IS TRUE", sql: "SELECT * FROM fx.users WHERE fx.users.active IS TRUE", allowed: {} },
    { name: "enum equality", sql: "SELECT * FROM fx.users WHERE fx.users.role = 'teacher'", allowed: {} },
    { name: "enum IN", sql: "SELECT * FROM fx.users WHERE fx.users.role IN ('teacher', 'admin')", allowed: {} },
    { name: "enum <>", sql: "SELECT * FROM fx.users WHERE fx.users.role <> 'student'", allowed: {} },
    { name: "IS NULL", sql: "SELECT * FROM fx.users WHERE fx.users.deleted_at IS NULL", allowed: {} },
    { name: "IS NOT NULL", sql: "SELECT * FROM fx.users WHERE fx.users.deleted_at IS NOT NULL", allowed: {} },
    { name: "LIKE prefix", sql: "SELECT * FROM fx.users WHERE fx.users.email LIKE 'ann%'", allowed: {} },
    { name: "ILIKE contains", sql: "SELECT * FROM fx.posts WHERE fx.posts.title ILIKE '%ruby%'", allowed: {} },
    { name: "NOT LIKE", sql: "SELECT * FROM fx.users WHERE fx.users.email NOT LIKE '%@spam.test'", allowed: {} },
    { name: "integer IN list", sql: "SELECT * FROM fx.posts WHERE fx.posts.id IN (1, 2, 3)", allowed: {} },
    { name: "text NOT IN list",
      sql: "SELECT * FROM fx.comments WHERE fx.comments.workflow_state NOT IN ('deleted', 'spam')", allowed: {} },
    { name: "= ANY array literal", sql: "SELECT * FROM fx.posts WHERE fx.posts.id = ANY('{4,5}'::bigint[])",
      allowed: {} },
    { name: "jsonb ->> equality", sql: "SELECT * FROM fx.users WHERE fx.users.settings ->> 'theme' = 'dark'",
      allowed: {} },
    { name: "jsonb @> containment", sql: "SELECT * FROM fx.users WHERE fx.users.settings @> '{\"beta\": true}'",
      allowed: {} },
    { name: "jsonb ? key", sql: "SELECT * FROM fx.users WHERE fx.users.settings ? 'theme'", allowed: {} },
    { name: "array @> containment", sql: "SELECT * FROM fx.posts WHERE fx.posts.labels @> ARRAY['ruby']", allowed: {} },
    { name: "array && overlap", sql: "SELECT * FROM fx.posts WHERE fx.posts.labels && ARRAY['ruby', 'go']",
      allowed: {} },
    { name: "literal = ANY(array column)", sql: "SELECT * FROM fx.posts WHERE 'ruby' = ANY(fx.posts.labels)",
      allowed: {} },
    { name: "lower() equality", sql: "SELECT * FROM fx.users WHERE lower(fx.users.email) = 'a@b'", allowed: {} },
    { name: "COALESCE filter", sql: "SELECT * FROM fx.posts WHERE COALESCE(fx.posts.body, '') <> ''", allowed: {} },
    { name: "length() filter", sql: "SELECT * FROM fx.posts WHERE length(fx.posts.title) > 5", allowed: {} },
    { name: "date_trunc filter",
      sql: "SELECT * FROM fx.posts WHERE date_trunc('day', fx.posts.created_at) = '2026-03-01'", allowed: {} },

    # AND / OR / NOT mixes.
    { name: "AND of three",
      sql: "SELECT * FROM fx.users WHERE fx.users.active = true AND fx.users.role = 'teacher' " \
           "AND fx.users.deleted_at IS NULL", allowed: {} },
    { name: "OR of two columns",
      sql: "SELECT * FROM fx.users WHERE fx.users.role = 'admin' OR fx.users.name = 'ann'", allowed: {} },
    { name: "OR on one column", sql: "SELECT * FROM fx.posts WHERE fx.posts.score = 1 OR fx.posts.score = 2",
      allowed: {} },
    { name: "AND with OR group",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.published = true AND (fx.posts.score > 5 OR fx.posts.body IS NULL)",
      allowed: {} },
    { name: "NOT of AND",
      sql: "SELECT * FROM fx.posts WHERE NOT (fx.posts.published = true AND fx.posts.score > 5)", allowed: {} },
    { name: "NOT of OR",
      sql: "SELECT * FROM fx.users WHERE NOT (fx.users.role = 'admin' OR fx.users.active = false)", allowed: {} },
    { name: "two OR groups ANDed",
      sql: "SELECT * FROM fx.posts WHERE (fx.posts.score = 1 OR fx.posts.score = 2) " \
           "AND (fx.posts.published = true OR fx.posts.body IS NULL)", allowed: {} },
    { name: "soft delete OR null",
      sql: "SELECT * FROM fx.users WHERE fx.users.deleted_at IS NULL OR fx.users.deleted_at > '2026-01-01'",
      allowed: {} },

    # Joins.
    { name: "inner join with parent filter",
      sql: "SELECT fx.posts.* FROM fx.posts JOIN fx.users ON fx.users.id = fx.posts.user_id " \
           "WHERE fx.users.active = true", allowed: {} },
    { name: "inner join with both filters",
      sql: "SELECT fx.posts.id FROM fx.posts JOIN fx.users ON fx.users.id = fx.posts.user_id " \
           "WHERE fx.users.role = 'teacher' AND fx.posts.published = true", allowed: {} },
    { name: "left join keeps parent",
      sql: "SELECT fx.users.id, fx.posts.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
           "WHERE fx.users.active = true", allowed: {} },
    { name: "left join anti (IS NULL)",
      sql: "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
           "WHERE fx.posts.id IS NULL", allowed: {} },
    { name: "left join with ON filter",
      sql: "SELECT fx.users.id, fx.posts.id FROM fx.users LEFT JOIN fx.posts " \
           "ON fx.posts.user_id = fx.users.id AND fx.posts.published = true", allowed: {} },
    { name: "right join",
      sql: "SELECT fx.users.id, fx.posts.id FROM fx.posts RIGHT JOIN fx.users ON fx.users.id = fx.posts.user_id " \
           "WHERE fx.users.role = 'admin'", allowed: {} },
    { name: "full join",
      sql: "SELECT fx.users.id, fx.posts.id FROM fx.users FULL JOIN fx.posts ON fx.posts.user_id = fx.users.id",
      allowed: {} },
    { name: "three-table FK chain",
      sql: "SELECT fx.comments.id FROM fx.comments JOIN fx.posts ON fx.posts.id = fx.comments.post_id " \
           "JOIN fx.users ON fx.users.id = fx.posts.user_id WHERE fx.users.active = true " \
           "AND fx.comments.workflow_state = 'active'", allowed: {} },
    { name: "four tables through a join table",
      sql: "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
           "JOIN fx.post_tags ON fx.post_tags.post_id = fx.posts.id JOIN fx.tags ON fx.tags.id = fx.post_tags.tag_id " \
           "WHERE fx.tags.name = 'ruby'", allowed: {} },
    { name: "join table IN on unique tag names",
      sql: "SELECT fx.posts.id FROM fx.posts JOIN fx.post_tags ON fx.post_tags.post_id = fx.posts.id " \
           "JOIN fx.tags ON fx.tags.id = fx.post_tags.tag_id WHERE fx.tags.name IN ('ruby', 'rails')", allowed: {} },
    { name: "self-join manager",
      sql: "SELECT e.id FROM fx.users e JOIN fx.users m ON m.id = e.manager_id WHERE m.role = 'admin'",
      allowed: {} },
    { name: "self-join both sides filtered",
      sql: "SELECT e.id FROM fx.users e JOIN fx.users m ON m.id = e.manager_id " \
           "WHERE m.active = true AND e.active = false", allowed: {} },
    { name: "comment author and post author join",
      sql: "SELECT fx.comments.id FROM fx.comments JOIN fx.posts ON fx.posts.id = fx.comments.post_id " \
           "WHERE fx.comments.user_id = fx.posts.user_id", allowed: {} },
    { name: "join on composite unique",
      sql: "SELECT fx.users.id FROM fx.users JOIN fx.memberships ON fx.memberships.user_id = fx.users.id " \
           "WHERE fx.memberships.group_name = 'g1' AND fx.memberships.kind = 'owner'", allowed: {} },
    { name: "polymorphic join to posts",
      sql: "SELECT fx.attachments.id FROM fx.attachments JOIN fx.posts ON fx.posts.id = fx.attachments.attachable_id " \
           "AND fx.attachments.attachable_type = 'Post' WHERE fx.posts.published = true", allowed: {} },
    { name: "polymorphic pair filter",
      sql: "SELECT * FROM fx.attachments WHERE fx.attachments.attachable_type = 'User' " \
           "AND fx.attachments.attachable_id = 7", allowed: {} },
    { name: "polymorphic pair IN",
      sql: "SELECT * FROM fx.attachments WHERE fx.attachments.attachable_type = 'Post' " \
           "AND fx.attachments.attachable_id IN (1, 2)", allowed: {} },
    { name: "implicit comma join",
      sql: "SELECT fx.posts.id FROM fx.posts, fx.users WHERE fx.users.id = fx.posts.user_id " \
           "AND fx.users.role = 'teacher'", allowed: {} },

    # Subqueries.
    { name: "IN subquery",
      sql: "SELECT * FROM fx.users WHERE fx.users.id IN (SELECT fx.posts.user_id FROM fx.posts " \
           "WHERE fx.posts.published = true)", allowed: {} },
    { name: "NOT IN subquery",
      sql: "SELECT * FROM fx.users WHERE fx.users.id NOT IN (SELECT fx.posts.user_id FROM fx.posts " \
           "WHERE fx.posts.score > 5)", allowed: {} },
    { name: "EXISTS correlated",
      sql: "SELECT * FROM fx.users WHERE EXISTS (SELECT 1 FROM fx.posts WHERE fx.posts.user_id = fx.users.id " \
           "AND fx.posts.published = true)", allowed: {} },
    { name: "NOT EXISTS correlated",
      sql: "SELECT * FROM fx.posts WHERE NOT EXISTS (SELECT 1 FROM fx.comments " \
           "WHERE fx.comments.post_id = fx.posts.id)", allowed: {} },
    { name: "scalar subquery in WHERE",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.score > (SELECT avg(p2.score) FROM fx.posts p2 " \
           "WHERE p2.published = true)", allowed: {} },
    { name: "correlated scalar count",
      sql: "SELECT * FROM fx.posts WHERE (SELECT count(*) FROM fx.comments " \
           "WHERE fx.comments.post_id = fx.posts.id) > 2", allowed: {} },
    { name: "scalar subquery in select list",
      sql: "SELECT fx.users.id, (SELECT count(*) FROM fx.posts WHERE fx.posts.user_id = fx.users.id " \
           "AND fx.posts.published = true) FROM fx.users WHERE fx.users.active = true", allowed: {} },
    { name: "derived table",
      sql: "SELECT t.user_id FROM (SELECT fx.posts.user_id FROM fx.posts WHERE fx.posts.score > 3) t",
      allowed: {} },
    { name: "nested IN subqueries",
      sql: "SELECT * FROM fx.comments WHERE fx.comments.post_id IN (SELECT fx.posts.id FROM fx.posts " \
           "WHERE fx.posts.user_id IN (SELECT fx.users.id FROM fx.users WHERE fx.users.role = 'teacher'))",
      allowed: {} },
    { name: "IN subquery on join table",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.id IN (SELECT fx.post_tags.post_id FROM fx.post_tags " \
           "WHERE fx.post_tags.tag_id = 3)", allowed: {} },

    # UNION, CTEs.
    { name: "UNION of two filters",
      sql: "SELECT fx.users.id FROM fx.users WHERE fx.users.role = 'admin' " \
           "UNION SELECT fx.posts.user_id FROM fx.posts WHERE fx.posts.score > 9", allowed: {} },
    { name: "UNION ALL same table",
      sql: "SELECT fx.posts.id FROM fx.posts WHERE fx.posts.published = true " \
           "UNION ALL SELECT fx.posts.id FROM fx.posts WHERE fx.posts.score > 9", allowed: {} },
    { name: "simple CTE",
      sql: "WITH active AS (SELECT fx.users.id FROM fx.users WHERE fx.users.active = true) " \
           "SELECT fx.posts.id FROM fx.posts JOIN active ON active.id = fx.posts.user_id", allowed: {} },
    { name: "CTE with outer filter",
      sql: "WITH recent AS (SELECT * FROM fx.posts WHERE fx.posts.created_at > '2026-01-01') " \
           "SELECT recent.id FROM recent WHERE recent.published = true", allowed: {} },
    { name: "two CTEs",
      sql: "WITH a AS (SELECT fx.users.id FROM fx.users WHERE fx.users.role = 'teacher'), " \
           "b AS (SELECT fx.posts.user_id FROM fx.posts WHERE fx.posts.published = true) " \
           "SELECT a.id FROM a JOIN b ON b.user_id = a.id", allowed: {} },

    # Grouping, aggregates, windows.
    { name: "GROUP BY with filter",
      sql: "SELECT fx.posts.user_id, count(*) FROM fx.posts WHERE fx.posts.published = true " \
           "GROUP BY fx.posts.user_id", allowed: {} },
    { name: "GROUP BY with HAVING",
      sql: "SELECT fx.posts.user_id, count(*) FROM fx.posts GROUP BY fx.posts.user_id HAVING count(*) > 1",
      allowed: {} },
    { name: "GROUP BY with WHERE and HAVING",
      sql: "SELECT fx.posts.user_id, sum(fx.posts.score) FROM fx.posts WHERE fx.posts.published = true " \
           "GROUP BY fx.posts.user_id HAVING sum(fx.posts.score) > 10", allowed: {} },
    { name: "count(*) with filter", sql: "SELECT count(*) FROM fx.posts WHERE fx.posts.score > 3", allowed: {} },
    { name: "count DISTINCT",
      sql: "SELECT count(DISTINCT fx.posts.user_id) FROM fx.posts WHERE fx.posts.published = true", allowed: {} },
    { name: "max with filter", sql: "SELECT max(fx.posts.score) FROM fx.posts WHERE fx.posts.published = true",
      allowed: {} },
    { name: "join GROUP BY parent",
      sql: "SELECT fx.users.role, count(fx.posts.id) FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
           "WHERE fx.posts.published = true GROUP BY fx.users.role", allowed: {} },
    { name: "window row_number",
      sql: "SELECT fx.posts.id, row_number() OVER (PARTITION BY fx.posts.user_id ORDER BY fx.posts.score) " \
           "FROM fx.posts WHERE fx.posts.published = true", allowed: {} },
    { name: "aggregate FILTER clause",
      sql: "SELECT count(*) FILTER (WHERE fx.posts.published) FROM fx.posts WHERE fx.posts.score > 0", allowed: {} },
    { name: "EXISTS existence check", sql: "SELECT 1 AS one FROM fx.users WHERE fx.users.email = 'a@b' LIMIT 1",
      allowed: {} },

    # DISTINCT, ORDER BY, LIMIT, OFFSET.
    { name: "DISTINCT on joined parent",
      sql: "SELECT DISTINCT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
           "WHERE fx.posts.published = true", allowed: {} },
    { name: "DISTINCT ON",
      sql: "SELECT DISTINCT ON (fx.posts.user_id) fx.posts.id FROM fx.posts WHERE fx.posts.published = true " \
           "ORDER BY fx.posts.user_id, fx.posts.created_at DESC", allowed: {} },
    { name: "ORDER BY LIMIT 10",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.published = true ORDER BY fx.posts.created_at DESC LIMIT 10",
      allowed: {} },
    { name: "ORDER BY id LIMIT OFFSET small",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.score > 1 ORDER BY fx.posts.id LIMIT 20 OFFSET 1", allowed: {} },
    { name: "keyset pagination",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.user_id = 4 AND fx.posts.id > 100 ORDER BY fx.posts.id LIMIT 25",
      allowed: {} },
    { name: "row comparison keyset",
      sql: "SELECT * FROM fx.posts WHERE (fx.posts.created_at, fx.posts.id) < ('2026-03-01', 50) " \
           "ORDER BY fx.posts.created_at DESC, fx.posts.id DESC LIMIT 25", allowed: {} },
    { name: "find_by LIMIT 1 on two columns",
      sql: "SELECT fx.users.* FROM fx.users WHERE fx.users.name = 'ann' AND fx.users.active = true LIMIT 1",
      allowed: {} },

    # Rails shapes.
    { name: "Rails find",
      sql: "SELECT \"fx\".\"users\".* FROM \"fx\".\"users\" WHERE \"fx\".\"users\".\"id\" = 5 LIMIT 1", allowed: {} },
    { name: "Rails has_many with order",
      sql: "SELECT fx.posts.* FROM fx.posts WHERE fx.posts.user_id = 5 ORDER BY fx.posts.created_at DESC",
      allowed: {} },
    { name: "Rails has_many through",
      sql: "SELECT fx.tags.* FROM fx.tags INNER JOIN fx.post_tags ON fx.tags.id = fx.post_tags.tag_id " \
           "WHERE fx.post_tags.post_id = 9", allowed: {} },
    { name: "Rails polymorphic has_many",
      sql: "SELECT fx.attachments.* FROM fx.attachments WHERE fx.attachments.attachable_id = 9 " \
           "AND fx.attachments.attachable_type = 'Post' ORDER BY fx.attachments.id", allowed: {} },
    { name: "Rails includes preload IN",
      sql: "SELECT fx.comments.* FROM fx.comments WHERE fx.comments.post_id IN (1, 2, 3, 4)", allowed: {} },
    { name: "Rails scope chain with joins",
      sql: "SELECT fx.posts.* FROM fx.posts INNER JOIN fx.users ON fx.users.id = fx.posts.user_id " \
           "WHERE fx.posts.published = true AND fx.users.deleted_at IS NULL AND fx.users.role = 'teacher' " \
           "ORDER BY fx.posts.id DESC LIMIT 20", allowed: {} },
    { name: "Rails exists?",
      sql: "SELECT 1 AS one FROM fx.memberships WHERE fx.memberships.user_id = 3 " \
           "AND fx.memberships.group_name = 'g1' LIMIT 1", allowed: {} },
    { name: "Rails count with where.not",
      sql: "SELECT COUNT(*) FROM fx.comments WHERE fx.comments.post_id = 3 AND fx.comments.workflow_state != 'deleted'",
      allowed: {} },
    { name: "Rails pluck distinct",
      sql: "SELECT DISTINCT fx.comments.user_id FROM fx.comments WHERE fx.comments.post_id IN (5, 6) " \
           "AND fx.comments.user_id IS NOT NULL", allowed: {} },
    { name: "Rails left_joins where nil",
      sql: "SELECT fx.posts.* FROM fx.posts LEFT OUTER JOIN fx.comments ON fx.comments.post_id = fx.posts.id " \
           "WHERE fx.comments.id IS NULL AND fx.posts.published = true", allowed: {} },
    { name: "Rails where with date range",
      sql: "SELECT fx.comments.* FROM fx.comments WHERE fx.comments.created_at >= '2026-01-01' " \
           "AND fx.comments.created_at < '2026-02-01'", allowed: {} },

    # Pinned keys: IN lists on primary or composite keys.
    { name: "IN on joined parent's key",
      sql: "SELECT fx.posts.* FROM fx.posts JOIN fx.users ON fx.users.id = fx.posts.user_id " \
           "WHERE fx.users.id IN (4, 5)", allowed: {} },
    { name: "IN on parent key with child filter",
      sql: "SELECT fx.comments.id FROM fx.comments JOIN fx.posts ON fx.posts.id = fx.comments.post_id " \
           "WHERE fx.posts.id IN (1, 2, 3) AND fx.comments.workflow_state <> 'deleted'", allowed: {} },
    { name: "IN on both composite key columns",
      sql: "SELECT * FROM fx.post_tags WHERE fx.post_tags.post_id IN (1, 2) AND fx.post_tags.tag_id IN (3, 4)",
      allowed: {} },
    { name: "IN on own key with polymorphic pair",
      sql: "SELECT * FROM fx.attachments WHERE fx.attachments.attachable_type = 'Post' " \
           "AND fx.attachments.attachable_id IN (1, 2) AND fx.attachments.id IN (5, 6)", allowed: {} },
    { name: "UNION ALL branches pinning the key",
      sql: "SELECT count(*) FROM fx.posts WHERE fx.posts.id IN (" \
           "SELECT fx.posts.id FROM fx.posts JOIN fx.comments ON fx.comments.post_id = fx.posts.id " \
           "WHERE fx.posts.published = true AND fx.comments.workflow_state = 'active' " \
           "UNION ALL SELECT fx.posts.id FROM fx.posts WHERE fx.posts.published = true " \
           "AND fx.posts.id IN (11, 12, 13))", allowed: {} },

    # Shapes with an allowed atom.
    { name: "implied lower bound",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.score > 5 AND fx.posts.score > 1",
      allowed: { "fx.posts.score > $2" => "redundant: score > 5 implies it, so no row fails it alone" } },
    { name: "OFFSET past the fixture",
      sql: "SELECT * FROM fx.posts WHERE fx.posts.score > 5 ORDER BY fx.posts.id LIMIT 20 OFFSET 40",
      allowed: { "fx.posts.score > $1" => "untestable: a fixture of a few rows returns nothing past OFFSET 40" } }
  ].freeze

  # Shapes in SHAPES that today leave a non-redundant atom untested, by
  # name: the untested set, pinned exactly, and a guess at the cause, which
  # isn't confirmed. Each is to become a backlog task pointing at 20261010-27.
  PENDING = {
    "max with filter" => {
      untested: ["fx.posts.published = $1"],
      cause: "the near miss needs a score above the hit's to change max(); nothing orders it so"
    },
    "aggregate FILTER clause" => {
      untested: ["fx.posts.score > $1"],
      cause: "the near miss may not satisfy the FILTER's published, so the count is unchanged"
    },
    "comment author and post author join" => {
      untested: ["fx.posts.id = fx.comments.post_id", "fx.comments.user_id = fx.posts.user_id"],
      cause: "a second column-to-column tie between the tables; no row joins on one and not the other"
    },
    "CTE with outer filter" => {
      untested: ["fx.posts.created_at > $1"],
      cause: "SELECT * in a CTE body with an outer filter; the near miss may fail the outer filter too"
    },
    "keyset pagination" => {
      untested: ["fx.posts.id > $2"],
      cause: "the id near miss can't share user_id with a PK pinned elsewhere, or sorts outside the cut"
    },
    "correlated scalar count" => {
      untested: ["fx.comments.post_id = fx.posts.id"],
      cause: "confirmed (20261010-30): S1 holds a post with no comment, but count(*) > 2 changes only " \
             "once more than 2 comments exist in all, and S1 builds 1"
    },
    "Rails count with where.not" => {
      untested: ["fx.comments.workflow_state <> $2"],
      cause: "unclear; plain count(*) with a filter passes, so maybe the pinned post_id = 3 near miss"
    },
    "boolean IS TRUE" => {
      untested: ["fx.users.active IS TRUE"],
      cause: "IS TRUE (a BooleanTest) seems to get no pool, so no false near miss"
    },
    "scalar subquery in WHERE" => {
      untested: ["p2.published = $1"],
      cause: "atom in an uncorrelated scalar subquery; its near miss must move avg() across the hit"
    }
  }.freeze

  def self.dump(entry, found)
    path = ENV.fetch("QUAACK_CORPUS_DUMP", nil)
    return unless path

    File.open(path, "a") { it.puts(JSON.generate(name: entry[:name], untested: found)) }
  end
end

RSpec.describe Quaack::Enclave::VacuityGuard do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before { conn.exec(VacuityCorpus::SCHEMA) }

  def untested(sql)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    described_class.run(runner, builder, sql).untested
  end

  it "has no shape name twice" do
    names = VacuityCorpus::SHAPES.map { it[:name] }
    expect(names.tally.select { |_, n| n > 1 }.keys).to eq([])
    expect(VacuityCorpus::PENDING.keys - names).to eq([])
  end

  describe "corpus" do
    VacuityCorpus::SHAPES.reject { VacuityCorpus::PENDING.key?(it[:name]) }.each do |entry|
      it "leaves only allowed atoms untested: #{entry[:name]}" do
        found = untested(entry[:sql])
        VacuityCorpus.dump(entry, found)
        expect(found.sort).to eq(entry[:allowed].keys.sort)
      end
    end
  end

  # Each pins today's gap exactly. When one goes red because the gap
  # closed, drop it from PENDING and give the shape what's left, if
  # anything, as its allow-list.
  describe "pending (known gaps, pinned)" do
    VacuityCorpus::SHAPES.select { VacuityCorpus::PENDING.key?(it[:name]) }.each do |entry|
      it "still leaves its known atoms untested: #{entry[:name]}" do
        found = untested(entry[:sql])
        VacuityCorpus.dump(entry, found)
        expect(found.sort).to eq(VacuityCorpus::PENDING.fetch(entry[:name])[:untested].sort)
      end
    end
  end
end
