# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' not_in_to_not_exists, on a real server: what it writes,
# that its output returns the rows its input does on data that would show a
# wrong transformation, and that it only fires when the catalog proves both
# columns not null and the shape is one where nothing else can go wrong.
RSpec.describe Quaack::Enclave::RewriteRules::NotInToNotExists do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # Account 1 holds users 1, 2, 3, and 5, and user 5 has no ref. Group 7
  # holds user 1 twice and user 4, and its last membership has no
  # loose_user_id. Group 8 holds user 2, group 9 user 3, group 10 nobody,
  # and no group is numbered 99.
  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, account_id int NOT NULL, ref int);
      CREATE TABLE public.memberships (id int PRIMARY KEY, user_id int NOT NULL, group_id int NOT NULL,
                                       loose_user_id int, big_user_id bigint NOT NULL);
      CREATE TABLE public.groups (id int PRIMARY KEY, kind text NOT NULL);
      CREATE TABLE public."my users" (id int PRIMARY KEY);
      CREATE VIEW public.members AS SELECT * FROM public.memberships;
      INSERT INTO public.users VALUES (1, 1, 1), (2, 1, 2), (3, 1, 3), (4, 2, 4), (5, 1, NULL);
      INSERT INTO public.memberships VALUES (1, 1, 7, 1, 1), (2, 1, 7, 1, 1), (3, 2, 8, 2, 2), (4, 4, 7, NULL, 4),
                                            (5, 3, 9, 3, 3);
      INSERT INTO public.groups VALUES (7, 'a'), (8, 'b'), (9, 'b'), (10, 'a');
      INSERT INTO public."my users" VALUES (1);
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

  def rows(sql, params = []) = conn.exec_params(sql, params).values.sort_by(&:to_s)

  # The original's rows, once every rewrite has been checked to return the same.
  def same_rows(sql, rewrites, params = [])
    expected = rows(sql, params)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params)).to eq(expected), "#{it} returns other rows" }
    expected
  end

  # What Rails writes for where.not(id: Membership.select(:user_id)).
  let(:fires) do
    "SELECT users.* FROM public.users WHERE users.account_id = $1 AND users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = $2)"
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["not_in_to_not_exists",
       "A NOT IN subquery whose tested columns and selected columns are all not null becomes a NOT EXISTS " \
       "correlated on each pair."]
    )
  end

  it "makes the NOT IN a NOT EXISTS, correlated by the equality NOT IN tested" do
    rewrites = rewritten(fires)

    expect(rewrites).to eq(
      ["SELECT users.* FROM public.users WHERE users.account_id = $1 AND NOT EXISTS " \
       "(SELECT 1 FROM public.memberships WHERE memberships.group_id = $2 AND users.id = memberships.user_id)"]
    )
  end

  it "returns the same rows with a match, a match twice over, no match, and an empty subquery" do
    rewrites = rewritten(fires)

    expect(same_rows(fires, rewrites, [1, 7]).map(&:first)).to eq(%w[2 3 5])
    expect(same_rows(fires, rewrites, [1, 99]).map(&:first)).to eq(%w[1 2 3 5])
    expect(same_rows(fires, rewrites, [2, 7])).to eq([])
    expect(same_rows(fires, rewrites, [2, 8]).map(&:first)).to eq(%w[4])
  end

  it "states both columns not null, in assumption-check's vocabulary" do
    expect(rule.rewrites(PgQuery.parse(fires), catalog).map(&:assumptions)).to eq(
      [[{ "kind" => "not_null", "table" => "public.users", "column" => "id" },
        { "kind" => "not_null", "table" => "public.memberships", "column" => "user_id" }]]
    )
  end

  it "doesn't change the parse it was given" do
    parse = PgQuery.parse(fires)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    rule.rewrites(parse, catalog)

    expect(parse.tree).to eq(before)
  end

  it "takes NOT (x IN ...), aliases, and a subquery with no WHERE" do
    sql = "SELECT u.id FROM public.users u WHERE NOT (u.id IN (SELECT m.user_id FROM public.memberships AS m))"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT u.id FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.memberships m WHERE u.id = m.user_id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["5"]])
  end

  it "keeps a subquery's OR apart from the correlation" do
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
          "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 8 OR memberships.id = 5)"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships WHERE " \
       "(memberships.group_id = 8 OR memberships.id = 5) AND users.id = memberships.user_id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["1"], ["4"], ["5"]])
  end

  it "drops a plain DISTINCT, which changes nothing NOT IN sees" do
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
          "(SELECT DISTINCT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7)"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships WHERE " \
       "memberships.group_id = 7 AND users.id = memberships.user_id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["5"]])
  end

  it "compares columns of different types with the operator NOT IN used" do
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
          "(SELECT memberships.big_user_id FROM public.memberships WHERE memberships.group_id = 7)"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships WHERE " \
       "memberships.group_id = 7 AND users.id = memberships.big_user_id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["5"]])
  end

  it "takes a subquery that joins, with the selected column's table on the kept side of an outer join" do
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
          "(SELECT memberships.user_id FROM public.memberships LEFT JOIN public.groups " \
          "ON groups.id = memberships.group_id AND groups.kind = 'a' WHERE groups.id IS NULL)"

    rewrites = rewritten(sql)

    expect(rewrites).to eq(
      ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships LEFT JOIN public.groups " \
       "ON groups.id = memberships.group_id AND groups.kind = 'a' WHERE groups.id IS NULL " \
       "AND users.id = memberships.user_id)"]
    )
    expect(same_rows(sql, rewrites)).to eq([["1"], ["4"], ["5"]])
  end

  it "takes a subquery that already reads the outer row, and one with a subquery of its own" do
    correlated = "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id " \
                 "FROM public.memberships WHERE memberships.group_id = users.account_id + 6)"
    nested = "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id " \
             "FROM public.memberships WHERE memberships.group_id IN (SELECT groups.id FROM public.groups " \
             "WHERE groups.kind = 'b'))"

    expect(same_rows(correlated, rewritten(correlated))).to eq([["2"], ["3"], ["4"], ["5"]])
    expect(same_rows(nested, rewritten(nested))).to eq([["1"], ["4"], ["5"]])
  end

  it "fires when the outer table is on the kept side of an outer join" do
    sql = "SELECT users.id, groups.id FROM public.users LEFT JOIN public.groups ON groups.id = users.id + 6 " \
          "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7)"
    mirrored = "SELECT users.id, groups.id FROM public.groups RIGHT JOIN public.users ON groups.id = users.id + 6 " \
               "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
               "WHERE memberships.group_id = 7)"

    expect(same_rows(sql, rewritten(sql))).to eq([%w[2 8], %w[3 9], ["5", nil]])
    expect(same_rows(mirrored, rewritten(mirrored))).to eq([%w[2 8], %w[3 9], ["5", nil]])
  end

  context "when the subquery reads a table under the outer table's name" do
    let(:shadowed) do
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
        "(SELECT users.id FROM public.users JOIN public.memberships ON memberships.user_id = users.id " \
        "WHERE users.account_id = 1 AND memberships.group_id = 7)"
    end

    it "gives the subquery's table a fresh alias, so the correlation reads the outer row" do
      rewrites = rewritten(shadowed)

      expect(rewrites).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.users users_1 " \
         "JOIN public.memberships ON memberships.user_id = users_1.id " \
         "WHERE users_1.account_id = 1 AND memberships.group_id = 7 AND users.id = users_1.id)"]
      )
      expect(same_rows(shadowed, rewrites)).to eq([["2"], ["3"], ["4"], ["5"]])
    end

    it "renames another table's alias too, when the selected column isn't that table's" do
      sql = "SELECT u.id FROM public.users u WHERE u.id NOT IN " \
            "(SELECT m.user_id FROM public.memberships m, public.groups u WHERE u.id = m.group_id AND u.kind = 'b')"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT u.id FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.memberships m, public.groups u_1 " \
         "WHERE u_1.id = m.group_id AND u_1.kind = 'b' AND u.id = m.user_id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["1"], ["4"], ["5"]])
    end

    it "states the one column both sides read once" do
      expect(rule.rewrites(PgQuery.parse(shadowed), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "not_null", "table" => "public.users", "column" => "id" }]]
      )
    end

    it "picks an alias no column in the query names" do
      sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
            "(SELECT users.id FROM public.users JOIN public.memberships users_1 ON users_1.user_id = users.id " \
            "WHERE users_1.group_id = 7)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.users users_2 " \
         "JOIN public.memberships users_1 ON users_1.user_id = users_2.id " \
         "WHERE users_1.group_id = 7 AND users.id = users_2.id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["2"], ["3"], ["5"]])
    end

    it "picks an alias no FROM item in the query has, even one no column names" do
      sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
            "(SELECT users.id FROM public.users CROSS JOIN public.groups users_1 WHERE users.account_id = 1)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.users users_2 " \
         "CROSS JOIN public.groups users_1 WHERE users_2.account_id = 1 AND users.id = users_2.id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["4"]])
    end

    it "picks an alias no table in the query is named, even one no column names" do
      conn.exec("CREATE TABLE public.users_1 (id int PRIMARY KEY); INSERT INTO public.users_1 VALUES (1)")
      sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
            "(SELECT users.id FROM public.users CROSS JOIN public.users_1 WHERE users.account_id = 1)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.users users_2 " \
         "CROSS JOIN public.users_1 WHERE users_2.account_id = 1 AND users.id = users_2.id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["4"]])
    end

    it "keeps the column names an alias gives when it renames the alias" do
      sql = "SELECT u.id FROM public.users u WHERE u.id NOT IN (SELECT m.user_id FROM public.memberships m, " \
            "public.groups u (gid, gkind) WHERE u.gid = m.group_id AND u.gkind = 'b')"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT u.id FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.memberships m, " \
         "public.groups u_1(gid, gkind) WHERE u_1.gid = m.group_id AND u_1.gkind = 'b' AND u.id = m.user_id)"]
      )
      expect(same_rows(sql, rewrites)).to eq([["1"], ["4"], ["5"]])
    end

    it "would be wrong without the alias: the correlation would compare the subquery's column with itself" do
      unaliased = "SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.users " \
                  "JOIN public.memberships ON memberships.user_id = users.id " \
                  "WHERE users.account_id = 1 AND memberships.group_id = 7 AND users.id = users.id)"

      expect(rows(unaliased)).not_to eq(rows(shadowed))
    end

    {
      "a column isn't qualified" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN " \
        "(SELECT users.id FROM public.users WHERE account_id = 2)",
      "it has a subquery of its own" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT users.id FROM public.users " \
        "WHERE EXISTS (SELECT 1 FROM public.memberships WHERE memberships.user_id = users.id))",
      "it has a subquery in its FROM" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT users.id FROM public.users, " \
        "(SELECT memberships.user_id FROM public.memberships) s WHERE s.user_id = users.id)",
      "the item of that name is a function" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id " \
        "FROM public.memberships, generate_series(1, 2) users WHERE memberships.group_id = 7)",
      "it has a whole-row reference" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN " \
        "(SELECT users.id FROM public.users WHERE users.* IS NOT NULL)",
      "it has a three-part column" =>
        "SELECT users.id FROM public.users WHERE users.id NOT IN " \
        "(SELECT users.id FROM public.users WHERE public.users.account_id = 2)"
    }.each do |why, sql|
      it "doesn't fire when #{why}, since the columns to rename can't all be found" do
        expect(rewritten(shadowed).size).to eq(1)
        expect(rewritten(sql)).to eq([])
      end
    end
  end

  it "doesn't fire on a column whose domain is NOT NULL, since such a column can hold NULL" do
    conn.exec(<<~SQL)
      CREATE DOMAIN public.user_ref AS int NOT NULL;
      CREATE TABLE public.notes (id int PRIMARY KEY, user_id public.user_ref);
      INSERT INTO public.notes VALUES (1, 1);
      INSERT INTO public.notes VALUES (2, (SELECT n.user_id FROM public.notes n WHERE false));
    SQL
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT notes.user_id FROM public.notes)"

    expect(rows("SELECT notes.id FROM public.notes WHERE notes.user_id IS NULL")).to eq([["2"]])
    expect(rows(sql)).to eq([])
    expect(rewritten(sql)).to eq([])
  end

  it "gives one rewrite per NOT IN, and the generator's second pass rewrites both" do
    sql = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
          "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7) AND users.id NOT IN " \
          "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 8)"
    first = "NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 AND " \
            "users.id = memberships.user_id)"
    second = "NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 8 AND " \
             "users.id = memberships.user_id)"

    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog, rules: [rule])

    expect(rewritten(sql)).to eq(generated.rewrites.first(2).map(&:sql))
    expect(generated.rewrites.map(&:sql)).to eq(
      ["SELECT users.id FROM public.users WHERE #{first} AND NOT users.id IN " \
       "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 8)",
       "SELECT users.id FROM public.users WHERE NOT users.id IN " \
       "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7) AND #{second}",
       "SELECT users.id FROM public.users WHERE #{first} AND #{second}"]
    )
    expect(same_rows(sql, generated.rewrites.map(&:sql))).to eq([["3"], ["5"]])
  end

  # Each is a query that fires, changed in one way that makes it unsafe or
  # unproven.
  {
    "the tested column is nullable" =>
      "SELECT users.* FROM public.users WHERE users.account_id = $1 AND users.ref NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = $2)",
    "the selected column is nullable" =>
      "SELECT users.* FROM public.users WHERE users.account_id = $1 AND users.id NOT IN " \
      "(SELECT memberships.loose_user_id FROM public.memberships WHERE memberships.group_id = $2)",
    "the selected column is a view's, which proves nothing" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT members.user_id FROM public.members)",
    "an assumption can't name the table" =>
      %(SELECT u.id FROM public."my users" u WHERE u.id NOT IN (SELECT m.user_id FROM public.memberships m)),
    "it's IN" =>
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT memberships.user_id FROM public.memberships)",
    "it's <> ALL" =>
      "SELECT users.id FROM public.users WHERE users.id <> ALL (SELECT memberships.user_id FROM public.memberships)",
    "it's NOT (= ANY)" =>
      "SELECT users.id FROM public.users WHERE NOT (users.id = ANY (SELECT memberships.user_id " \
      "FROM public.memberships))",
    "it's NOT EXISTS already" =>
      "SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT memberships.user_id FROM public.memberships)",
    "it's a NOT IN list" => "SELECT users.id FROM public.users WHERE users.id NOT IN (1, 2)",
    "the NOT IN is under an OR" =>
      "SELECT users.id FROM public.users WHERE users.account_id = 2 OR users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "an IN is the first arm of an OR" =>
      "SELECT users.id FROM public.users WHERE users.id IN (SELECT memberships.user_id FROM public.memberships) " \
      "OR users.account_id = 2",
    "the NOT IN is under another NOT" =>
      "SELECT users.id FROM public.users WHERE NOT (users.id NOT IN (SELECT memberships.user_id " \
      "FROM public.memberships))",
    "the NOT IN is in the select list" =>
      "SELECT users.id NOT IN (SELECT memberships.user_id FROM public.memberships) FROM public.users",
    "the NOT IN is in a join's ON" =>
      "SELECT users.id FROM public.users JOIN public.groups ON users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the NOT IN is in a subquery" =>
      "SELECT g.id FROM public.groups g WHERE EXISTS (SELECT 1 FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships))",
    "the query is a UNION" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships) " \
      "UNION ALL SELECT groups.id FROM public.groups",
    "the tested column isn't qualified" =>
      "SELECT users.id FROM public.users WHERE id NOT IN (SELECT memberships.user_id FROM public.memberships)",
    "the tested expression isn't a column" =>
      "SELECT users.id FROM public.users WHERE users.id + 0 NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the tested column is a three-part name" =>
      "SELECT users.id FROM public.users WHERE public.users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer table is on the nullable side of a LEFT JOIN" =>
      "SELECT groups.id FROM public.groups LEFT JOIN public.users ON users.id = groups.id " \
      "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships)",
    "the outer table is on the nullable side of a RIGHT JOIN" =>
      "SELECT groups.id FROM public.users RIGHT JOIN public.groups ON users.id = groups.id " \
      "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships)",
    "the outer table is in a FULL JOIN" =>
      "SELECT groups.id FROM public.users FULL JOIN public.groups ON users.id = groups.id " \
      "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships)",
    "the outer name is a subquery's" =>
      "SELECT users.id FROM (SELECT * FROM public.users) users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer name is a join's alias" =>
      "SELECT j.id FROM (public.users JOIN public.groups g ON g.id = users.id) j WHERE j.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer FROM has an item with no name of its own" =>
      "SELECT users.id FROM public.users, generate_series(1, 2) WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer table is read with ONLY" =>
      "SELECT users.id FROM ONLY public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer table's alias renames columns" =>
      "SELECT users.id FROM public.users users (id, account_id) WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the outer table is a CTE" =>
      "WITH users AS (SELECT * FROM public.users) SELECT users.id FROM users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships)",
    "the subquery selects two columns' worth with *" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.* FROM public.memberships)",
    "the selected column isn't qualified" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT user_id FROM public.memberships)",
    "the subquery selects an expression" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id + 0 FROM public.memberships)",
    "the subquery selects an aggregate" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT max(memberships.user_id) FROM public.memberships)",
    "the subquery selects a window function" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT max(memberships.user_id) OVER () FROM public.memberships)",
    "the subquery selects the outer table's column" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT users.id FROM public.memberships)",
    "the subquery is a VALUES list" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (VALUES (1), (2))",
    "the selected column's table is on the nullable side of a LEFT JOIN" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.groups " \
      "LEFT JOIN public.memberships ON memberships.group_id = groups.id)",
    "the selected column's table is on the nullable side of a RIGHT JOIN" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
      "RIGHT JOIN public.groups ON memberships.group_id = groups.id)",
    "the selected column's table is in a FULL JOIN" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
      "FULL JOIN public.groups ON memberships.group_id = groups.id)",
    "the selected column is a subquery's" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT m.user_id FROM (SELECT * FROM public.memberships) m)",
    "the selected column is a CTE's" =>
      "WITH m AS (SELECT * FROM public.memberships) SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT m.user_id FROM m)",
    "the selected column's table is read with ONLY" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM ONLY public.memberships)",
    "the selected column's table has an alias that renames columns" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT m.user_id FROM public.memberships m (user_id, id))",
    "the subquery's join has an alias" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT m.user_id FROM " \
      "(public.memberships JOIN public.groups ON groups.id = memberships.group_id) m)",
    "the subquery's FROM has an item with no name of its own" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships, generate_series(1, 2))",
    "the subquery has GROUP BY" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships GROUP BY memberships.user_id)",
    "the subquery has HAVING" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships HAVING true)",
    "the subquery has a WINDOW clause" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships WINDOW w AS ())",
    "the subquery has ORDER BY" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships ORDER BY memberships.id)",
    "the subquery has LIMIT" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships LIMIT 1)",
    "the subquery has OFFSET" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships OFFSET 1)",
    "the subquery locks rows" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT memberships.user_id FROM public.memberships FOR UPDATE)",
    "the subquery has a WITH" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(WITH w AS (SELECT 1) SELECT memberships.user_id FROM public.memberships)",
    "the subquery has DISTINCT ON" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN " \
      "(SELECT DISTINCT ON (memberships.group_id) memberships.user_id FROM public.memberships)",
    "the subquery is a UNION ALL" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
      "UNION ALL SELECT memberships.user_id FROM public.memberships)",
    "the subquery is an EXCEPT" =>
      "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
      "EXCEPT SELECT groups.id FROM public.groups)"
  }.each do |why, sql|
    it "doesn't fire when #{why}" do
      expect(rewritten(fires).size).to eq(1)
      expect(rewritten(sql)).to eq([])
    end
  end

  # Each grant gives a user an account. The pairs (user_id, account_id) are
  # (1, 1) twice, (4, 1), (2, 2), and (5, 1). Grant 2 has no
  # loose_account_id, and grant 5 no loose_user_id.
  context "with a row on the left" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.grants (id int PRIMARY KEY, user_id int NOT NULL, account_id int NOT NULL,
                                    loose_user_id int, loose_account_id int);
        INSERT INTO public.grants VALUES (1, 1, 1, 1, 1), (2, 4, 1, 4, NULL), (3, 2, 2, 2, 2), (4, 1, 1, 1, 1),
                                         (5, 5, 1, NULL, 1);
      SQL
    end

    let(:row) do
      "SELECT users.id FROM public.users WHERE (users.id, users.account_id) NOT IN " \
        "(SELECT grants.user_id, grants.account_id FROM public.grants WHERE grants.id < $1)"
    end

    it "correlates each column of the row with the column the subquery selects in its place" do
      expect(rewritten(row)).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.grants WHERE grants.id < $1 " \
         "AND users.id = grants.user_id AND users.account_id = grants.account_id)"]
      )
    end

    it "returns the same rows with matches, a match on one column only, and an empty subquery" do
      rewrites = rewritten(row)

      expect(same_rows(row, rewrites, [99]).map(&:first)).to eq(%w[2 3 4])
      expect(same_rows(row, rewrites, [5]).map(&:first)).to eq(%w[2 3 4 5])
      expect(same_rows(row, rewrites, [0]).map(&:first)).to eq(%w[1 2 3 4 5])
    end

    it "states every column on both sides not null, pair by pair" do
      expect(rule.rewrites(PgQuery.parse(row), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "not_null", "table" => "public.users", "column" => "id" },
          { "kind" => "not_null", "table" => "public.grants", "column" => "user_id" },
          { "kind" => "not_null", "table" => "public.users", "column" => "account_id" },
          { "kind" => "not_null", "table" => "public.grants", "column" => "account_id" }]]
      )
    end

    it "takes ROW(...), and a row of one column" do
      explicit = row.sub("(users.id, users.account_id)", "ROW(users.id, users.account_id)")
      single = "SELECT users.id FROM public.users WHERE ROW(users.id) NOT IN (SELECT grants.user_id FROM public.grants)"

      expect(rewritten(single)).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.grants " \
         "WHERE users.id = grants.user_id)"]
      )
      expect(same_rows(explicit, rewritten(explicit), [99]).map(&:first)).to eq(%w[2 3 4])
      expect(same_rows(single, rewritten(single)).map(&:first)).to eq(%w[3])
    end

    it "takes an unqualified column in the subquery's WHERE, when no subquery table has an outer name" do
      sql = "SELECT users.id FROM public.users WHERE (users.id, users.account_id) NOT IN " \
            "(SELECT grants.user_id, grants.account_id FROM public.grants WHERE loose_user_id IS NOT NULL)"

      expect(rewritten(sql)).to eq(
        ["SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.grants WHERE " \
         "loose_user_id IS NOT NULL AND users.id = grants.user_id AND users.account_id = grants.account_id)"]
      )
      expect(same_rows(sql, rewritten(sql)).map(&:first)).to eq(%w[2 3 4 5])
    end

    it "takes a row whose columns are different outer tables'" do
      sql = "SELECT users.id FROM public.users, public.users other WHERE other.id = users.id AND " \
            "(users.id, other.account_id) NOT IN (SELECT grants.user_id, grants.account_id FROM public.grants)"

      expect(rewritten(sql)).to eq(
        ["SELECT users.id FROM public.users, public.users other WHERE other.id = users.id AND NOT EXISTS " \
         "(SELECT 1 FROM public.grants WHERE users.id = grants.user_id AND other.account_id = grants.account_id)"]
      )
      expect(same_rows(sql, rewritten(sql)).map(&:first)).to eq(%w[2 3 4])
    end

    it "gives a fresh alias to each subquery table under the name of a table the row reads" do
      sql = "SELECT u.id FROM public.users u, public.grants g WHERE g.id = 1 AND (u.id, g.account_id) NOT IN " \
            "(SELECT u.user_id, g.account_id FROM public.grants u, public.users g WHERE g.id = u.user_id)"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT u.id FROM public.users u, public.grants g WHERE g.id = 1 AND NOT EXISTS (SELECT 1 " \
         "FROM public.grants u_1, public.users g_1 WHERE g_1.id = u_1.user_id AND u.id = u_1.user_id " \
         "AND g.account_id = g_1.account_id)"]
      )
      expect(same_rows(sql, rewrites).map(&:first)).to eq(%w[3 4])
    end

    # Each is the row query changed in one way that makes it unsafe or
    # unproven.
    {
      "the row's first column is nullable" => ["(users.id, users.account_id)", "(users.ref, users.account_id)"],
      "the row's second column is nullable" => ["(users.id, users.account_id)", "(users.id, users.ref)"],
      "the first selected column is nullable" => ["grants.user_id, grants.account_id",
                                                  "grants.loose_user_id, grants.account_id"],
      "the second selected column is nullable" => ["grants.user_id, grants.account_id",
                                                   "grants.user_id, grants.loose_account_id"],
      "a column of the row isn't qualified" => ["(users.id, users.account_id)", "(users.id, account_id)"],
      "a column of the row is an expression" => ["(users.id, users.account_id)", "(users.id, users.account_id + 0)"],
      "a selected column is an expression" => ["grants.user_id, grants.account_id",
                                               "grants.user_id, grants.account_id + 0"],
      "the subquery selects fewer columns than the row has" => ["grants.user_id, grants.account_id",
                                                                "grants.user_id"],
      "the subquery selects more columns than the row has" => ["grants.user_id, grants.account_id",
                                                               "grants.user_id, grants.account_id, grants.id"],
      "the row is empty" => ["(users.id, users.account_id) NOT IN (SELECT grants.user_id, grants.account_id",
                             "ROW() NOT IN (SELECT"],
      "a column of the row is on the nullable side of a LEFT JOIN" =>
        ["FROM public.users WHERE (users.id, users.account_id)",
         "FROM public.users LEFT JOIN public.groups ON groups.id = users.id + 6 WHERE (users.id, groups.id)"]
    }.each do |why, (from, to)|
      it "doesn't fire when #{why}" do
        sql = row.sub(from, to)

        expect(sql).not_to eq(row)
        expect(rewritten(row).size).to eq(1)
        expect(rewritten(sql)).to eq([])
      end
    end

    # What the rule would write on the row query, with the given columns,
    # if it fired anyway.
    def forced_row(tested, selected)
      equalities = tested.zip(selected).map { "#{it.first} = #{it.last}" }.join(" AND ")
      "SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM public.grants WHERE #{equalities})"
    end

    def original_row(tested, selected)
      "SELECT users.id FROM public.users WHERE (#{tested.join(", ")}) NOT IN " \
        "(SELECT #{selected.join(", ")} FROM public.grants)"
    end

    {
      "a nullable column of the row, when the other column matches" =>
        [%w[users.id users.ref], %w[grants.user_id grants.account_id], [["3"], ["4"]], [["3"], ["4"], ["5"]]],
      "a nullable second selected column, when the first matches" =>
        [%w[users.id users.account_id], %w[grants.user_id grants.loose_account_id], [["2"], ["3"]],
         [["2"], ["3"], ["4"]]],
      "a nullable first selected column, when the second matches" =>
        [%w[users.id users.account_id], %w[grants.loose_user_id grants.account_id], [["4"]],
         [["2"], ["3"], ["4"], ["5"]]]
    }.each do |why, (tested, selected, not_in, not_exists)|
      it "would be wrong on #{why}: the row comparison is unknown, so NOT IN drops the row" do
        expect(rows(original_row(tested, selected))).to eq(not_in)
        expect(rows(forced_row(tested, selected))).to eq(not_exists)
        expect(rewritten(original_row(tested, selected))).to eq([])
      end
    end
  end

  # app.users and app.memberships have public's names, but their columns
  # are nullable and each holds a NULL. app.people and app.visits are only
  # in app, with columns that are not null.
  context "with another schema, some of whose tables have public's names" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA app;
        CREATE TABLE app.users (id int);
        CREATE TABLE app.memberships (user_id int, group_id int NOT NULL);
        CREATE TABLE app.people (id int PRIMARY KEY);
        CREATE TABLE app.visits (person_id int NOT NULL);
        INSERT INTO app.users VALUES (2), (NULL);
        INSERT INTO app.memberships VALUES (1, 7), (NULL, 7);
        INSERT INTO app.people VALUES (1), (2);
        INSERT INTO app.visits VALUES (1), (1);
      SQL
    end

    it "fires on that schema's tables, and names them by it in the assumptions" do
      sql = "SELECT people.id FROM app.people WHERE people.id NOT IN (SELECT visits.person_id FROM app.visits)"

      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "not_null", "table" => "app.people", "column" => "id" },
          { "kind" => "not_null", "table" => "app.visits", "column" => "person_id" }]]
      )
      expect(same_rows(sql, rewritten(sql))).to eq([["2"]])
    end

    it "doesn't fire on a nullable tested column whose table has the name of a public one that's not null" do
      original = "SELECT users.id FROM app.users WHERE users.id NOT IN " \
                 "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7)"
      not_exists = "SELECT users.id FROM app.users WHERE NOT EXISTS (SELECT 1 FROM public.memberships " \
                   "WHERE memberships.group_id = 7 AND users.id = memberships.user_id)"

      expect(rewritten(original.sub("app.users", "public.users")).size).to eq(1)
      expect(rewritten(original)).to eq([])
      expect(rows(original)).to eq([["2"]])
      expect(rows(not_exists)).to eq([["2"], [nil]])
    end

    it "doesn't fire on a nullable selected column whose table has the name of a public one that's not null" do
      original = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
                 "(SELECT memberships.user_id FROM app.memberships WHERE memberships.group_id = 7)"
      not_exists = "SELECT users.id FROM public.users WHERE NOT EXISTS (SELECT 1 FROM app.memberships " \
                   "WHERE memberships.group_id = 7 AND users.id = memberships.user_id)"

      expect(rewritten(original.sub("app.memberships", "public.memberships")).size).to eq(1)
      expect(rewritten(original)).to eq([])
      expect(rows(original)).to eq([])
      expect(rows(not_exists)).to eq([["2"], ["3"], ["4"], ["5"]])
    end
  end

  # What the rule would write if it fired anyway.
  def forced(column, subquery) = "SELECT users.id FROM public.users WHERE NOT EXISTS (#{subquery} = #{column})"

  it "would be wrong on a nullable selected column: one NULL makes NOT IN give no rows" do
    original = "SELECT users.id FROM public.users WHERE users.id NOT IN " \
               "(SELECT memberships.loose_user_id FROM public.memberships WHERE memberships.group_id = 7)"
    not_exists = forced("users.id", "SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 AND " \
                                    "memberships.loose_user_id")

    expect(rows(original)).to eq([])
    expect(rows(not_exists)).to eq([["2"], ["3"], ["4"], ["5"]])
  end

  it "would be wrong on a nullable tested column: NOT IN drops the NULL row, and NOT EXISTS keeps it" do
    original = "SELECT users.id FROM public.users WHERE users.ref NOT IN " \
               "(SELECT memberships.user_id FROM public.memberships WHERE memberships.group_id = 7)"
    not_exists = forced("users.ref", "SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 AND " \
                                     "memberships.user_id")

    expect(rows(original)).to eq([["2"], ["3"]])
    expect(rows(not_exists)).to eq([["2"], ["3"], ["5"]])
  end

  it "would be wrong on a selected column an outer join can fill with NULL, not null though it is" do
    original = "SELECT users.id FROM public.users WHERE users.id NOT IN (SELECT memberships.user_id " \
               "FROM public.groups LEFT JOIN public.memberships ON memberships.group_id = groups.id)"
    not_exists = forced("users.id", "SELECT 1 FROM public.groups LEFT JOIN public.memberships " \
                                    "ON memberships.group_id = groups.id WHERE memberships.user_id")

    expect(rows(original)).to eq([])
    expect(rows(not_exists)).to eq([["5"]])
  end

  it "would be wrong on an outer table an outer join can fill with NULL" do
    original = "SELECT groups.id FROM public.groups LEFT JOIN public.users ON users.id = groups.id - 4 " \
               "WHERE users.id NOT IN (SELECT memberships.user_id FROM public.memberships " \
               "WHERE memberships.group_id = 7)"
    not_exists = "SELECT groups.id FROM public.groups LEFT JOIN public.users ON users.id = groups.id - 4 " \
                 "WHERE NOT EXISTS (SELECT 1 FROM public.memberships WHERE memberships.group_id = 7 " \
                 "AND memberships.user_id = users.id)"

    expect(rows(original)).to eq([["7"], ["9"]])
    expect(rows(not_exists)).to eq([["10"], ["7"], ["9"]])
  end
end
