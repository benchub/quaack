# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' not_in_to_not_exists in every position its condition can
# sit in (any SELECT's WHERE, HAVING, select list, join ON, CASE), and as
# <> ALL, on a real server. With every tested and selected column proven
# not null the condition is never NULL, so NOT EXISTS gives the same value
# wherever it is. The tests check that on data with NULLs on both sides, an
# empty subquery, and duplicates, and that each guard, taken away, gives
# other rows.
RSpec.describe Quaack::Enclave::RewriteRules::NotInToNotExists do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Users 1 to 5, user 5 with no ref and user 4 in account 2. Memberships
  # name users 1 (twice), 2, 3, and 4, in groups 7, 8, and 9, and two
  # have no loose_user_id. Group 10 has no membership. No group is 99.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, account_id int NOT NULL, ref int);
      CREATE TABLE public.memberships (id int PRIMARY KEY, user_id int NOT NULL, group_id int NOT NULL,
                                       loose_user_id int);
      CREATE TABLE public.groups (id int PRIMARY KEY, kind text NOT NULL);
      INSERT INTO public.users VALUES (1, 1, 1), (2, 1, 2), (3, 1, 3), (4, 2, 4), (5, 1, NULL);
      INSERT INTO public.memberships VALUES (1, 1, 7, 1), (2, 1, 7, 1), (3, 2, 8, NULL), (4, 4, 7, NULL), (5, 3, 9, 3);
      INSERT INTO public.groups VALUES (7, 'a'), (8, 'b'), (9, 'b'), (10, 'a');
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def rows(sql) = conn.exec(sql).values.sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the same.
  def same_rows(sql, rewrites)
    expected = rows(sql)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  let(:in_group7) { "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7)" }
  let(:not_exists7) do
    "NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 AND users.id = memberships.user_id)"
  end

  context "with NOT IN outside the top-level WHERE" do
    it "takes one under an OR" do
      sql = "SELECT users.id FROM public.users WHERE users.account_id = 2 OR users.id NOT IN #{in_group7}"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(["SELECT users.id FROM public.users WHERE users.account_id = 2 OR #{not_exists7}"])
      expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["4"], ["5"]])
    end

    it "takes one under another NOT, and under a NOT of a parenthesized AND" do
      under = "SELECT users.id FROM public.users WHERE NOT (users.id NOT IN #{in_group7})"
      anded = "SELECT users.id FROM public.users WHERE NOT (users.id NOT IN #{in_group7} AND users.account_id = 1)"

      expect(same_rows(under, rewritten(under))).to eq([["1"], ["4"]])
      expect(same_rows(anded, rewritten(anded))).to eq([["1"], ["4"]])
    end

    it "takes one in the select list, where it's a value" do
      sql = "SELECT users.id, users.id NOT IN #{in_group7} FROM public.users"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(["SELECT users.id, #{not_exists7} FROM public.users"])
      expect(same_rows(sql, rewrites)).to eq([%w[1 f], %w[2 t], %w[3 t], %w[4 f], %w[5 t]])
    end

    it "takes one in a CASE" do
      sql = "SELECT users.id, CASE WHEN users.id NOT IN #{in_group7} THEN 'free' ELSE 'taken' END FROM public.users"

      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 taken], %w[2 free], %w[3 free], %w[4 taken], %w[5 free]])
    end

    it "takes one in an inner join's ON, and in a LEFT JOIN's ON about the kept side" do
      inner = "SELECT users.id, groups.id FROM public.users JOIN public.groups ON groups.id = 8 " \
              "AND users.id NOT IN #{in_group7}"
      left = "SELECT users.id, groups.id FROM public.users LEFT JOIN public.groups ON groups.id = 8 " \
             "AND users.id NOT IN #{in_group7}"

      expect(same_rows(inner, rewritten(inner))).to eq([%w[2 8], %w[3 8], %w[5 8]])
      expect(same_rows(left, rewritten(left))).to eq([["1", nil], %w[2 8], %w[3 8], ["4", nil], %w[5 8]])
    end

    it "takes one in a HAVING on a grouped column" do
      sql = "SELECT users.account_id, count(*) FROM public.users GROUP BY users.account_id, users.id " \
            "HAVING users.id NOT IN #{in_group7}"

      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 1], %w[1 1], %w[1 1]])
    end

    it "takes one in a subquery's WHERE, in a FROM subquery, and in a CTE" do
      exists = "SELECT groups.id FROM public.groups WHERE EXISTS (SELECT 1 FROM public.users " \
               "WHERE users.id NOT IN #{in_group7} AND users.account_id = groups.id - 7)"
      derived = "SELECT d.id FROM (SELECT users.id FROM public.users WHERE users.id NOT IN #{in_group7}) d"
      cte = "WITH d AS (SELECT users.id FROM public.users WHERE users.id NOT IN #{in_group7}) SELECT d.id FROM d"

      expect(same_rows(exists, rewritten(exists))).to eq([["8"]])
      expect(same_rows(derived, rewritten(derived))).to eq([["2"], ["3"], ["5"]])
      expect(same_rows(cte, rewritten(cte))).to eq([["2"], ["3"], ["5"]])
    end

    it "takes one in each branch of a UNION query" do
      sql = "SELECT users.id FROM public.users WHERE users.id NOT IN #{in_group7} " \
            "UNION ALL SELECT users.id FROM public.users WHERE users.account_id = 2 AND users.id NOT IN #{in_group7}"

      rewrites = rewritten(sql)

      expect(rewrites.size).to eq(2)
      expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["5"]])
    end

    it "gives one rewrite for each condition, each changing only its own" do
      sql = "SELECT users.id, users.id NOT IN #{in_group7} FROM public.users " \
            "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 8)"

      rewrites = rewritten(sql)

      expect(rewrites.size).to eq(2)
      expect(rewrites.map { it.scan("NOT EXISTS").size }).to eq([1, 1])
      expect(same_rows(sql, rewrites)).to eq([%w[1 f], %w[3 t], %w[4 f], %w[5 t]])
    end

    it "makes a UNION subquery an AND of NOT EXISTS where it sits, in the select list or under an OR" do
      union = "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 8 " \
              "UNION SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 9)"
      select_list = "SELECT users.id, users.id NOT IN #{union} FROM public.users"
      disjunct = "SELECT users.id FROM public.users WHERE users.id = 1 OR users.id NOT IN #{union}"

      expect(rewritten(select_list).first).to match(/\ASELECT users.id, NOT EXISTS \(.*\) AND NOT EXISTS \(.*\) FROM/)
      expect(same_rows(select_list, rewritten(select_list))).to eq([%w[1 t], %w[2 f], %w[3 f], %w[4 t], %w[5 t]])
      expect(same_rows(disjunct, rewritten(disjunct))).to eq([["1"], ["4"], ["5"]])
    end

    it "states the not-null assumptions of the condition's own tables" do
      sql = "SELECT g.id FROM public.groups g WHERE EXISTS (SELECT 1 FROM public.users " \
            "WHERE users.id NOT IN #{in_group7})"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "not_null", "table" => "public.users", "column" => "id" },
          { "kind" => "not_null", "table" => "public.memberships", "column" => "user_id" }]]
      )
    end

    # NOT IN is NULL, not false, for a NULL tested value, or a NULL in the
    # subquery that doesn't match: a WHERE drops both, so only a position
    # that shows the value tells them from NOT EXISTS's true.
    it "doesn't take a nullable tested column in the select list, where NULL is a value" do
      sql = "SELECT users.id, users.ref NOT IN #{in_group7} FROM public.users"
      forced = "SELECT users.id, NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 " \
               "AND users.ref = memberships.user_id) FROM public.users"

      expect(rewritten(sql)).to eq([])
      expect(rows(sql)).to eq([%w[1 f], %w[2 t], %w[3 t], %w[4 f], ["5", nil]])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a nullable selected column in the select list" do
      sql = "SELECT users.id, users.id NOT IN (SELECT memberships.loose_user_id FROM public.memberships) " \
            "FROM public.users"
      forced = "SELECT users.id, NOT EXISTS (SELECT 1 FROM public.memberships " \
               "WHERE users.id = memberships.loose_user_id) FROM public.users"

      expect(rewritten(sql)).to eq([])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a nullable tested column under IS NULL, which asks whether the condition is unknown" do
      sql = "SELECT users.id FROM public.users WHERE (users.ref NOT IN #{in_group7}) IS NULL"
      forced = "SELECT users.id FROM public.users WHERE (#{not_exists7.sub("users.id", "users.ref")}) IS NULL"

      expect(rewritten(sql)).to eq([])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a tested column an outer join can fill with NULL, in the select list" do
      sql = "SELECT groups.id, users.id NOT IN #{in_group7} FROM public.groups LEFT JOIN public.users " \
            "ON users.id = groups.id - 9"
      forced = "SELECT groups.id, NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 " \
               "AND users.id = memberships.user_id) FROM public.groups LEFT JOIN public.users " \
               "ON users.id = groups.id - 9"

      expect(rewritten(sql)).to eq([])
      expect(rows(sql)).to include(["7", nil])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a table on the nullable side of the join whose ON holds it" do
      sql = "SELECT groups.id FROM public.groups LEFT JOIN public.users ON users.id NOT IN #{in_group7}"

      expect(rewritten(sql)).to eq([])
    end

    it "doesn't take a condition under a grouping set, which fills a grouped column with NULL" do
      sql = "SELECT users.id, users.id NOT IN #{in_group7} FROM public.users GROUP BY ROLLUP (users.id)"
      forced = "SELECT users.id, #{not_exists7} FROM public.users GROUP BY ROLLUP (users.id)"

      expect(rewritten(sql)).to eq([])
      expect(rows(sql)).to include([nil, nil])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a column of another scope, which the condition's SELECT doesn't have" do
      sql = "SELECT groups.id FROM public.groups WHERE EXISTS (SELECT 1 FROM public.memberships " \
            "WHERE memberships.group_id = groups.id AND groups.id NOT IN (SELECT users.id FROM public.users))"

      expect(rewritten(sql)).to eq([])
    end
  end

  context "with <> ALL" do
    let(:all7) { "users.id <> ALL #{in_group7}" }

    it "becomes the NOT EXISTS NOT IN would" do
      sql = "SELECT users.id FROM public.users WHERE #{all7}"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(["SELECT users.id FROM public.users WHERE #{not_exists7}"])
      expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["5"]])
    end

    it "returns the same rows with a match, a duplicate, no match, and an empty subquery" do
      none = "SELECT users.id FROM public.users WHERE users.id <> ALL " \
             "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 99)"
      everyone = "SELECT users.id FROM public.users WHERE users.id <> ALL " \
                 "(SELECT memberships.user_id FROM public.memberships)"

      expect(same_rows(none, rewritten(none)).size).to eq(5)
      expect(same_rows(everyone, rewritten(everyone))).to eq([["5"]])
    end

    it "reads != the same, and takes a NOT of it, a value, an OR, and a UNION" do
      ne = "SELECT users.id FROM public.users WHERE users.id != ALL #{in_group7}"
      negated = "SELECT users.id FROM public.users WHERE NOT (#{all7})"
      value = "SELECT users.id, #{all7} FROM public.users"
      either = "SELECT users.id FROM public.users WHERE users.id = 1 OR #{all7}"
      union = "SELECT users.id FROM public.users WHERE users.id <> ALL (SELECT memberships.user_id " \
              "FROM public.memberships WHERE memberships.group_id = 8 UNION SELECT memberships.user_id " \
              "FROM public.memberships WHERE memberships.group_id = 9)"

      expect(same_rows(ne, rewritten(ne))).to eq([["2"], ["3"], ["5"]])
      expect(same_rows(negated, rewritten(negated))).to eq([["1"], ["4"]])
      expect(same_rows(value, rewritten(value))).to eq([%w[1 f], %w[2 t], %w[3 t], %w[4 f], %w[5 t]])
      expect(same_rows(either, rewritten(either))).to eq([["1"], ["2"], ["3"], ["5"]])
      expect(same_rows(union, rewritten(union))).to eq([["1"], ["4"], ["5"]])
    end

    it "lists the columns it proved not null" do
      sql = "SELECT users.id FROM public.users WHERE #{all7}"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "not_null", "table" => "public.users", "column" => "id" },
          { "kind" => "not_null", "table" => "public.memberships", "column" => "user_id" }]]
      )
    end

    it "doesn't take a nullable selected column, where <> ALL gives no rows or NULL" do
      sql = "SELECT users.id FROM public.users WHERE users.id <> ALL (SELECT memberships.loose_user_id " \
            "FROM public.memberships)"
      forced = "SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships " \
               "WHERE users.id = memberships.loose_user_id)"

      expect(rewritten(sql)).to eq([])
      expect(rows(sql)).to eq([])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take a nullable tested column" do
      sql = "SELECT users.id FROM public.users WHERE users.ref <> ALL #{in_group7}"

      expect(rewritten(sql)).to eq([])
    end

    it "doesn't take a row, another operator, or ANY" do
      [
        "SELECT users.id FROM public.users WHERE (users.id, users.account_id) <> ALL " \
        "(SELECT memberships.user_id, memberships.group_id FROM public.memberships)",
        "SELECT users.id FROM public.users WHERE users.id = ALL #{in_group7}",
        "SELECT users.id FROM public.users WHERE users.id < ALL #{in_group7}",
        "SELECT users.id FROM public.users WHERE users.id <> ANY #{in_group7}",
        "SELECT users.id FROM public.users WHERE users.id OPERATOR(pg_catalog.<>) ALL #{in_group7}",
        "SELECT users.id FROM public.users WHERE users.id <> ALL (ARRAY[1, 2])"
      ].each { expect(rewritten(it)).to eq([]), it }
    end

    # A type whose <> isn't the negation of its =, here a composite with
    # operators of its own, so x <> ALL isn't NOT IN. Postgres picks those
    # operators for the columns, and the rule asks that they be pg_catalog's
    # negators of each other, as they are for every type Postgres ships.
    it "doesn't take a type whose <> isn't the negator of its =" do
      conn.exec(<<~SQL)
        CREATE TYPE public.wrapper AS (v int);
        CREATE FUNCTION public.w_eq(public.wrapper, public.wrapper) RETURNS boolean
          LANGUAGE sql IMMUTABLE AS 'SELECT ($1).v % 2 = ($2).v % 2';
        CREATE FUNCTION public.w_ne(public.wrapper, public.wrapper) RETURNS boolean
          LANGUAGE sql IMMUTABLE AS 'SELECT ($1).v % 3 <> ($2).v % 3';
        CREATE OPERATOR public.= (LEFTARG = public.wrapper, RIGHTARG = public.wrapper, FUNCTION = public.w_eq);
        CREATE OPERATOR public.<> (LEFTARG = public.wrapper, RIGHTARG = public.wrapper, FUNCTION = public.w_ne);
        CREATE TABLE public.lefts (id int PRIMARY KEY, w public.wrapper NOT NULL);
        CREATE TABLE public.rights (id int PRIMARY KEY, w public.wrapper NOT NULL);
        INSERT INTO public.lefts VALUES (1, ROW(1)), (2, ROW(2)), (3, ROW(3));
        INSERT INTO public.rights VALUES (1, ROW(4)), (2, ROW(6));
      SQL
      sql = "SELECT lefts.id FROM public.lefts WHERE lefts.w <> ALL (SELECT rights.w FROM public.rights)"
      forced = "SELECT lefts.id FROM public.lefts WHERE NOT EXISTS (SELECT 1 FROM public.rights " \
               "WHERE lefts.w = rights.w)"

      expect(rewritten(sql)).to eq([])
      expect(rows(forced)).not_to eq(rows(sql))
    end

    it "doesn't take columns of another collation" do
      conn.exec(<<~SQL)
        CREATE TABLE public.names (id int PRIMARY KEY, a text COLLATE "C" NOT NULL, b text COLLATE "POSIX" NOT NULL);
      SQL
      same = "SELECT names.id FROM public.names WHERE names.a <> ALL (SELECT n.a FROM public.names n)"
      other = "SELECT names.id FROM public.names WHERE names.a <> ALL (SELECT n.b FROM public.names n)"

      expect(rewritten(same).size).to eq(1)
      expect(rewritten(other)).to eq([])
    end
  end
end
