# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/literals"
require "quaack/enclave/rewrite_rules/union_outer_filter_removal"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' union_outer_filter_removal, on a real server: a top-level
# WHERE conjunct on a UNION subquery's columns goes when every arm's WHERE
# already applies it to the column the arm outputs there, and every rewrite
# returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::UnionOuterFilterRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # The users_in_account CTE's body, with its account as a literal.
  def body(account = 1) = "SELECT user_id FROM public.user_account_associations WHERE account_id = #{account}"

  # A SELECT of users' id and workflow_state with this WHERE.
  def arm(where, from: "public.users", columns: "users.id, users.workflow_state")
    "SELECT #{columns} FROM #{from} WHERE #{where}"
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, name text, workflow_state text);
      CREATE TABLE public.big_users (id bigint PRIMARY KEY, name text, workflow_state text);
      CREATE TABLE public.c_users (id int PRIMARY KEY, name text, workflow_state text COLLATE "C");
      CREATE TABLE public.user_account_associations (id int PRIMARY KEY, user_id int, account_id int);
      CREATE TABLE public.pseudonyms (id int PRIMARY KEY, user_id int, unique_id text);
      INSERT INTO public.users VALUES
        (1, 'a', 'active'), (2, 'b', 'deleted'), (3, NULL, 'active'), (4, 'd', NULL), (5, 'a', 'active'),
        (6, 'a', 'deleted'), (7, 'a', 'active');
      INSERT INTO public.big_users SELECT * FROM public.users;
      INSERT INTO public.c_users SELECT * FROM public.users;
      INSERT INTO public.user_account_associations VALUES
        (1, 1, 1), (2, 1, 1), (3, 2, 1), (4, 3, 1), (5, NULL, 1), (6, 4, 2), (7, 5, NULL), (8, 3, 2), (9, 6, 1),
        (10, 7, 1);
      INSERT INTO public.pseudonyms VALUES (1, 1, 'x'), (2, 1, 'y'), (3, 3, NULL), (4, 5, 'z'), (5, NULL, 'w'),
        (6, 7, 'x');
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

  # sql's rows are rewrite's, and aren't empty.
  def expect_same_rows(sql, rewrite)
    original = redacted(sql)
    want = rows(original.sql, original.placeholder_map)
    expect(want).not_to be_empty
    expect(rows(rewrite, original.placeholder_map)).to eq(want)
  end

  # The rewrite of sql is exactly expected, and returns sql's rows.
  def expect_rewrite(sql, expected)
    expect(rewritten(sql)).to eq([expected])
    expect_same_rows(sql, expected)
  end

  # For each [refused, fires] pair, the rule leaves refused alone and
  # rewrites fires, its positive twin. Both run on the server.
  def expect_refusals(pairs)
    pairs.each do |refused, fires|
      expect(conn.exec(refused).ntuples).to be_positive, refused
      expect(rewritten(refused)).to eq([]), refused
      expect(rewritten(fires).size).to eq(1), fires
    end
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["union_outer_filter_removal",
       "A WHERE conjunct on a UNION subquery's columns is removed when every arm's WHERE already applies it to " \
       "the column it outputs."]
    )
  end

  it "drops an outer conjunct that every arm applies, and keeps the others" do
    expect_rewrite(
      "SELECT u.id, u.workflow_state FROM (" \
      "#{arm("users.name = 'a' AND users.workflow_state <> 'deleted'")} " \
      "UNION #{arm("users.workflow_state <> 'deleted' AND users.id < 4")}) u " \
      "WHERE u.workflow_state <> 'deleted' AND u.id > 1",
      "SELECT u.id, u.workflow_state FROM (" \
      "SELECT users.id, users.workflow_state FROM public.users WHERE users.name = $1 AND users.workflow_state <> $2 " \
      "UNION SELECT users.id, users.workflow_state FROM public.users WHERE users.workflow_state <> $3 " \
      "AND users.id < $4) u WHERE u.id > $6"
    )
  end

  it "drops the whole WHERE when it was the only conjunct, keeping UNION ALL's duplicate rows" do
    expect_rewrite(
      "SELECT u.workflow_state FROM (" \
      "#{arm("users.workflow_state <> 'deleted'", columns: "users.workflow_state")} " \
      "UNION ALL #{arm("users.workflow_state <> 'deleted' AND users.name = 'a'", columns: "users.workflow_state")}" \
      ") u WHERE u.workflow_state <> 'deleted'",
      "SELECT u.workflow_state FROM (SELECT users.workflow_state FROM public.users WHERE users.workflow_state <> $1 " \
      "UNION ALL SELECT users.workflow_state FROM public.users WHERE users.workflow_state <> $2 " \
      "AND users.name = $3) u"
    )
  end

  it "maps columns by position, through the arms' own names and their stars" do
    expect_rewrite(
      "SELECT u.uid FROM (SELECT users.id AS uid, users.name FROM public.users WHERE users.id > 2 " \
      "UNION SELECT p.user_id, p.unique_id FROM public.pseudonyms p WHERE p.user_id > 2 " \
      "UNION SELECT users.id, users.name FROM public.users JOIN public.pseudonyms p ON p.user_id = users.id " \
      "WHERE users.id > 2) u WHERE u.uid > 2",
      "SELECT u.uid FROM ((SELECT users.id AS uid, users.name FROM public.users WHERE users.id > $1 " \
      "UNION SELECT p.user_id, p.unique_id FROM public.pseudonyms p WHERE p.user_id > $2) " \
      "UNION SELECT users.id, users.name FROM public.users JOIN public.pseudonyms p ON p.user_id = users.id " \
      "WHERE users.id > $3) u"
    )
    expect_rewrite(
      "SELECT u.name FROM (SELECT users.* FROM public.users WHERE users.workflow_state <> 'deleted' " \
      "UNION SELECT * FROM public.users WHERE users.workflow_state <> 'deleted') u " \
      "WHERE u.workflow_state <> 'deleted'",
      "SELECT u.name FROM (SELECT users.* FROM public.users WHERE users.workflow_state <> $1 " \
      "UNION SELECT * FROM public.users WHERE users.workflow_state <> $2) u"
    )
  end

  it "drops an IN over the top-level CTE that every arm reads too" do
    expect_rewrite(
      "WITH users_in_account AS MATERIALIZED (#{body}) SELECT u.id FROM (" \
      "#{arm("users.id IN (SELECT user_id FROM users_in_account) AND users.name = 'a'")} " \
      "UNION #{arm("users.workflow_state = 'active' AND users.id IN (SELECT user_id FROM users_in_account)")}) u " \
      "WHERE u.id IN (SELECT user_id FROM users_in_account)",
      "WITH users_in_account AS MATERIALIZED (SELECT user_id FROM public.user_account_associations " \
      "WHERE account_id = $1) SELECT u.id FROM (SELECT users.id, users.workflow_state FROM public.users " \
      "WHERE users.id IN (SELECT user_id FROM users_in_account) AND users.name = $2 " \
      "UNION SELECT users.id, users.workflow_state FROM public.users WHERE users.workflow_state = $3 " \
      "AND users.id IN (SELECT user_id FROM users_in_account)) u"
    )
  end

  it "drops an IN whose subquery has its own matching WITH in every arm" do
    cte = "WITH a AS (#{body}) SELECT user_id FROM a"
    expect_rewrite(
      "SELECT u.id FROM (#{arm("users.id IN (#{cte})")} UNION #{arm("users.id IN (#{cte}) AND users.id > 1")}) u " \
      "WHERE u.id IN (#{cte})",
      "SELECT u.id FROM (SELECT users.id, users.workflow_state FROM public.users WHERE users.id IN " \
      "(WITH a AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $1) " \
      "SELECT user_id FROM a) UNION SELECT users.id, users.workflow_state FROM public.users WHERE users.id IN " \
      "(WITH a AS (SELECT user_id FROM public.user_account_associations WHERE account_id = $2) " \
      "SELECT user_id FROM a) AND users.id > $3) u"
    )
  end

  it "handles a nested UNION's arms, and arms with GROUP BY, DISTINCT ON, ORDER BY, and LIMIT" do
    expect_rewrite(
      "SELECT u.id FROM ((#{arm("users.id > 1")} UNION ALL " \
      "(SELECT DISTINCT ON (users.workflow_state) users.id, users.workflow_state FROM public.users " \
      "WHERE users.id > 1 ORDER BY users.workflow_state, users.id)) " \
      "UNION (SELECT users.id, users.workflow_state FROM public.users WHERE users.id > 1 " \
      "GROUP BY users.id, users.workflow_state ORDER BY users.id LIMIT 3)) u WHERE u.id > 1",
      "SELECT u.id FROM ((SELECT users.id, users.workflow_state FROM public.users WHERE users.id > $1 UNION ALL " \
      "(SELECT DISTINCT ON (users.workflow_state) users.id, users.workflow_state FROM public.users " \
      "WHERE users.id > $2 ORDER BY users.workflow_state, users.id)) " \
      "UNION (SELECT users.id, users.workflow_state FROM public.users WHERE users.id > $3 " \
      "GROUP BY users.id, users.workflow_state ORDER BY users.id LIMIT $4)) u"
    )
  end

  it "drops a conjunct of a UNION under inner joins, an outer join's kept side, and an aggregate" do
    union = "(#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.workflow_state <> 'deleted'")}) u"
    expect_rewrite(
      "SELECT p.unique_id, u.id FROM public.pseudonyms p JOIN #{union} ON u.id = p.user_id " \
      "WHERE u.workflow_state <> 'deleted' AND p.unique_id IS NOT NULL",
      "SELECT p.unique_id, u.id FROM public.pseudonyms p JOIN (SELECT users.id, users.workflow_state " \
      "FROM public.users WHERE users.workflow_state <> $1 UNION SELECT users.id, users.workflow_state " \
      "FROM public.users WHERE users.workflow_state <> $2) u ON u.id = p.user_id WHERE p.unique_id IS NOT NULL"
    )
    expect_rewrite(
      "SELECT u.id, p.unique_id FROM #{union} LEFT JOIN public.pseudonyms p ON u.id = p.user_id " \
      "WHERE u.workflow_state <> 'deleted'",
      "SELECT u.id, p.unique_id FROM (SELECT users.id, users.workflow_state FROM public.users " \
      "WHERE users.workflow_state <> $1 UNION SELECT users.id, users.workflow_state FROM public.users " \
      "WHERE users.workflow_state <> $2) u LEFT JOIN public.pseudonyms p ON u.id = p.user_id"
    )
    expect_rewrite(
      "SELECT u.workflow_state, count(*) FROM #{union} WHERE u.workflow_state <> 'deleted' " \
      "GROUP BY u.workflow_state HAVING count(*) > 1",
      "SELECT u.workflow_state, count(*) FROM (SELECT users.id, users.workflow_state FROM public.users " \
      "WHERE users.workflow_state <> $1 UNION SELECT users.id, users.workflow_state FROM public.users " \
      "WHERE users.workflow_state <> $2) u GROUP BY u.workflow_state HAVING count(*) > $4"
    )
  end

  it "drops the users_in_account and workflow_state filters from a Canvas user search, after cte_hoist_dedupe" do
    cte = "WITH users_in_account AS MATERIALIZED (#{body}) SELECT user_id FROM users_in_account"
    arms = ["users.name = 'a'", "users.name IS NULL",
            "users.id IN (SELECT pseudonyms.user_id FROM public.pseudonyms WHERE pseudonyms.unique_id = 'x')",
            "users.workflow_state = 'active'", "users.id = 4"].map do |filter|
      "SELECT users.* FROM public.users WHERE #{filter} AND users.id IN (#{cte}) " \
        "AND users.workflow_state <> 'deleted'"
    end
    sql = "SELECT users.* FROM (#{arms.join(" UNION ")}) users " \
          "WHERE users.id IN (#{cte}) AND users.workflow_state <> 'deleted' ORDER BY users.id"
    expected = "WITH users_in_account AS MATERIALIZED (SELECT user_id FROM public.user_account_associations " \
               "WHERE account_id = $2) SELECT users.* FROM ((((" \
               "SELECT users.* FROM public.users WHERE users.name = $1 AND users.id IN " \
               "(SELECT user_id FROM users_in_account) AND users.workflow_state <> $3 " \
               "UNION SELECT users.* FROM public.users WHERE users.name IS NULL AND users.id IN " \
               "(SELECT user_id FROM users_in_account) AND users.workflow_state <> $5) " \
               "UNION SELECT users.* FROM public.users WHERE users.id IN (SELECT pseudonyms.user_id " \
               "FROM public.pseudonyms WHERE pseudonyms.unique_id = $6) AND users.id IN " \
               "(SELECT user_id FROM users_in_account) AND users.workflow_state <> $8) " \
               "UNION SELECT users.* FROM public.users WHERE users.workflow_state = $9 AND users.id IN " \
               "(SELECT user_id FROM users_in_account) AND users.workflow_state <> $11) " \
               "UNION SELECT users.* FROM public.users WHERE users.id = $12 AND users.id IN " \
               "(SELECT user_id FROM users_in_account) AND users.workflow_state <> $14) users ORDER BY users.id"
    redacted, literals = literals_for(sql)

    generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(redacted), catalog, literals)
    chained = generated.rewrites.find { it.rules.map(&:name) == %w[cte_hoist_dedupe union_outer_filter_removal] }

    expect(chained&.sql).to eq(expected)
    expect_same_rows(sql, expected)
  end

  it "keeps a conjunct that an arm lacks, or applies with another literal", :aggregate_failures do
    [
      "#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.id > 0")}",
      "#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.workflow_state <> 'gone'")}",
      "#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.workflow_state <> 'deleted' OR users.id > 0")}",
      "#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.name <> 'deleted'")}",
      "#{arm("users.workflow_state <> 'deleted'")} UNION " \
      "#{arm("users.workflow_state <> 'deleted'", columns: "users.id, users.name")}"
    ].each do |union|
      sql = "SELECT u.id FROM (#{union}) u WHERE u.workflow_state <> 'deleted'"

      expect(conn.exec(sql).ntuples).to be_positive, union
      expect(rewritten(sql)).to eq([]), union
    end
  end

  it "refuses a conjunct that calls a volatile function" do
    union = ->(test) { "SELECT u.id FROM (#{arm(test)} UNION #{arm(test)}) u WHERE #{test.sub("users.", "u.")}" }

    expect_refusals([[union.call("users.id < random() * 10"), union.call("users.id < abs(10)")]])
  end

  it "refuses a column an arm outputs as an aggregate, a window function, or a set-returning function" do
    union = lambda do |select, group = ""|
      "SELECT u.id FROM (#{arm("users.id > 1")} UNION #{select} WHERE users.id > 1#{group}) u WHERE u.id > 1"
    end
    users = "users.workflow_state FROM public.users"
    expect_refusals(
      [[union.call("SELECT max(users.id) AS id, #{users}", " GROUP BY users.workflow_state"),
        union.call("SELECT users.id, #{users}", " GROUP BY users.id, users.workflow_state")],
       [union.call("SELECT max(users.id) OVER (PARTITION BY users.workflow_state) AS id, #{users}"),
        union.call("SELECT users.id, (max(users.id) OVER (PARTITION BY users.workflow_state))::text " \
                   "FROM public.users")],
       [union.call("SELECT generate_series(users.id, users.id + 1) AS id, #{users}"),
        union.call("SELECT users.id, #{users}, generate_series(1, 2) g")]]
    )
  end

  it "refuses a conjunct an arm has only in HAVING" do
    plain = arm("users.workflow_state <> 'deleted'")
    grouped = "SELECT users.id, users.workflow_state FROM public.users"
    expect_refusals(
      [["SELECT u.id FROM (#{plain} UNION #{grouped} GROUP BY users.id, users.workflow_state " \
        "HAVING users.workflow_state <> 'deleted') u WHERE u.workflow_state <> 'deleted'",
        "SELECT u.id FROM (#{plain} UNION #{grouped} WHERE users.workflow_state <> 'deleted' " \
        "GROUP BY users.id, users.workflow_state) u WHERE u.workflow_state <> 'deleted'"]]
    )
  end

  it "refuses an arm grouped by ROLLUP, whose total row has a NULL the outer conjunct drops" do
    grouped = "SELECT users.workflow_state, count(*) FROM public.users WHERE users.workflow_state <> $1 GROUP BY"
    sql = lambda do |group|
      "SELECT u.workflow_state FROM (#{grouped} users.workflow_state UNION #{grouped} #{group}) u " \
        "WHERE u.workflow_state <> $1"
    end
    _, literals = literals_for("SELECT 'deleted'")
    rollup = sql.call("ROLLUP (users.workflow_state)")

    expect(conn.exec_params("#{grouped} ROLLUP (users.workflow_state)", ["deleted"]).column_values(0)).to include(nil)
    expect(rule.rewrites(PgQuery.parse(rollup), catalog, literals)).to eq([])
    expect(rule.rewrites(PgQuery.parse(sql.call("users.workflow_state")), catalog, literals).size).to eq(1)
  end

  it "refuses a subquery that isn't all UNIONs of SELECTs: INTERSECT, EXCEPT, VALUES, or no set operation" do
    one = arm("users.id > 1")
    other = arm("users.id > 1 AND users.name = 'a'")
    expect_refusals(
      ["INTERSECT", "EXCEPT", "INTERSECT ALL"].map do |op|
        ["SELECT u.id FROM (#{one} #{op} #{other}) u WHERE u.id > 1",
         "SELECT u.id FROM (#{one} UNION #{other}) u WHERE u.id > 1"]
      end + [["SELECT u.id FROM ((#{one} EXCEPT #{other}) UNION #{one}) u WHERE u.id > 1",
              "SELECT u.id FROM ((#{one} UNION #{other}) UNION #{one}) u WHERE u.id > 1"],
             ["SELECT u.column1 FROM (VALUES (2, 'active') UNION #{one}) u WHERE u.column1 > 1",
              "SELECT u.id FROM (#{other} UNION #{one}) u WHERE u.id > 1"],
             ["SELECT u.id FROM (#{one} UNION VALUES (2, 'active')) u WHERE u.id > 1",
              "SELECT u.id FROM (#{one} UNION #{other}) u WHERE u.id > 1"],
             ["SELECT u.id FROM (#{one}) u WHERE u.id > 1",
              "SELECT u.id FROM (#{one} UNION ALL #{one}) u WHERE u.id > 1"]]
    )
  end

  it "refuses a conjunct that reads another FROM item, even inside its subquery" do
    from = "public.users JOIN public.pseudonyms p ON p.user_id = users.id"
    correlated = "users.id IN (SELECT a.user_id FROM public.user_account_associations a WHERE a.id = p.id)"
    plain = "users.id IN (SELECT a.user_id FROM public.user_account_associations a WHERE a.id > 1)"
    union = ->(test) { "(#{arm(test, from:)} UNION #{arm("#{test} AND users.id > 0", from:)}) u" }
    outer = ->(test) { test.sub("users.id IN", "u.id IN") }
    expect_refusals(
      [["SELECT u.id FROM public.pseudonyms p JOIN #{union.call("users.id = p.user_id")} ON true " \
        "WHERE u.id = p.user_id",
        "SELECT u.id FROM public.pseudonyms p JOIN #{union.call("users.id > 1")} ON true WHERE u.id > 1"],
       ["SELECT u.id FROM public.pseudonyms p JOIN #{union.call("users.id >= users.id")} ON u.id = p.user_id " \
        "WHERE u.id >= p.id",
        "SELECT u.id FROM public.pseudonyms p JOIN #{union.call("users.id >= users.id")} ON u.id = p.user_id " \
        "WHERE u.id >= u.id"],
       ["SELECT u.id FROM public.pseudonyms p JOIN #{union.call(correlated)} ON u.id = p.user_id " \
        "WHERE #{outer.call(correlated)}",
        "SELECT u.id FROM public.pseudonyms p JOIN #{union.call(plain)} ON u.id = p.user_id " \
        "WHERE #{outer.call(plain)}"]]
    )
  end

  it "refuses a column whose type or collation differs between arms" do
    expect_refusals(
      [["public.big_users users", "public.users", "u.id > 1"],
       ["public.c_users users", "public.users", "u.workflow_state <> 'deleted'"]].map do |refused, fires, where|
        [refused, fires].map do |from|
          "SELECT u.id FROM (#{arm("users.workflow_state <> 'deleted' AND users.id > 1")} " \
            "UNION #{arm("users.workflow_state <> 'deleted' AND users.id > 1", from:)}) u WHERE #{where}"
        end
      end
    )
  end

  it "refuses a LATERAL UNION" do
    union = ->(where) { "(#{arm(where)} UNION #{arm(where)}) u" }
    filter = "users.workflow_state <> 'deleted'"
    expect_refusals(
      [["SELECT u.id FROM public.pseudonyms p, LATERAL #{union.call("#{filter} AND users.id = p.user_id")} " \
        "WHERE u.workflow_state <> 'deleted'",
        "SELECT u.id FROM public.pseudonyms p, #{union.call("#{filter} AND users.id > 0")} " \
        "WHERE u.workflow_state <> 'deleted'"]]
    )
  end

  it "refuses a UNION on an outer join's nullable side, where dropping the conjunct would add rows" do
    union = "(#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.workflow_state <> 'deleted'")}) u"
    fires = "SELECT p.id FROM public.pseudonyms p JOIN #{union} ON u.id = p.user_id WHERE u.workflow_state <> 'deleted'"
    expect_refusals(
      %w[LEFT FULL].map do |join|
        ["SELECT p.id FROM public.pseudonyms p #{join} JOIN #{union} ON u.id = p.user_id " \
         "WHERE u.workflow_state <> 'deleted'", fires]
      end + [["SELECT p.id FROM #{union} RIGHT JOIN public.pseudonyms p ON u.id = p.user_id " \
              "WHERE u.workflow_state <> 'deleted'", fires]]
    )
  end

  it "refuses a subquery CTE that a nearer WITH of the same name hides, but not a table of that name" do
    inner = "WITH users_in_account AS (#{body(2)}) "
    filter = "users.id IN (SELECT user_id FROM users_in_account)"
    outer = "WITH users_in_account AS (#{body}) SELECT u.id FROM ("
    tail = ") u WHERE u.id IN (SELECT user_id FROM users_in_account)"
    expect_refusals(
      [["#{outer}#{inner}#{arm(filter)} UNION #{arm(filter)}#{tail}",
        "#{outer}#{arm(filter)} UNION #{arm(filter)}#{tail}"],
       ["#{outer}(#{inner}#{arm(filter)}) UNION #{arm(filter)}#{tail}",
        "#{outer}(#{arm(filter)}) UNION #{arm(filter)}#{tail}"]]
    )
    table = "users.id IN (SELECT a.user_id FROM public.user_account_associations a WHERE a.account_id = 1)"
    sql = "SELECT u.id FROM (WITH user_account_associations AS (SELECT 1) #{arm(table)} UNION #{arm(table)}) u " \
          "WHERE #{table.sub("users.id", "u.id")}"
    rewrites = rewritten(sql)

    expect(rewrites.size).to eq(1)
    expect_same_rows(sql, rewrites.first)
  end

  it "refuses a star it can't expand, an arm reading a CTE, and a table the catalog lacks" do
    from = "public.users JOIN public.pseudonyms p ON p.user_id = users.id"
    filter = "users.workflow_state <> 'deleted'"
    star = lambda do |columns|
      "SELECT u.workflow_state FROM (#{arm(filter, from:, columns:)} UNION #{arm(filter, from:, columns:)}) u " \
        "WHERE u.workflow_state <> 'deleted'"
    end
    cte = lambda do |first, second|
      "WITH c AS (SELECT * FROM public.users) SELECT u.id FROM (#{arm(filter, from: first)} " \
        "UNION #{arm(filter, from: second)}) u WHERE u.workflow_state <> 'deleted'"
    end
    expect_refusals([[star.call("*"), star.call("users.*")],
                     [cte.call("c users", "public.users"), cte.call("public.users", "public.users")],
                     [cte.call("c users", "c users"), cte.call("public.users", "public.users")]])
    missing = "SELECT u.id FROM (#{arm(filter, from: "public.nosuch users")} UNION #{arm(filter)}) u " \
              "WHERE u.workflow_state <> 'deleted'"
    nosuch = arm(filter, from: "public.nosuch n, public.users", columns: "n.*, users.id, users.workflow_state")
    missing_star = "SELECT u.id FROM (#{arm(filter)} UNION #{nosuch}) u WHERE u.workflow_state <> 'deleted'"

    expect([rewritten(missing), rewritten(missing_star)]).to eq([[], []])
    expect(rewritten(missing.sub("public.nosuch", "public.users")).size).to eq(1)
    expect(rewritten(missing_star.sub("public.nosuch n, ", "").sub("n.*, ", "")).size).to eq(1)
  end

  it "refuses column aliases on the UNION or an arm's table, and an outer column it can't place" do
    union = "(#{arm("users.workflow_state <> 'deleted'")} UNION #{arm("users.workflow_state <> 'deleted'")})"
    named = arm("users.name <> 'deleted'", columns: "users.name, users.workflow_state")
    aliased = lambda do |columns, aliases|
      "SELECT u.id FROM (#{arm("users.workflow_state <> 'deleted'", columns: columns.gsub("x.", "users."))} UNION " \
        "#{arm("x.workflow_state <> 'deleted'", from: "public.users x#{aliases}", columns:)}) u " \
        "WHERE u.workflow_state <> 'deleted'"
    end
    expect_refusals(
      [["SELECT u.id FROM #{union} u (id, state) WHERE u.state <> 'deleted'",
        "SELECT u.id FROM #{union} u WHERE u.workflow_state <> 'deleted'"],
       ["SELECT u.name FROM (#{named} UNION #{named}) u (workflow_state, name) WHERE u.name <> 'deleted'",
        "SELECT u.name FROM (#{named} UNION #{named}) u WHERE u.name <> 'deleted'"],
       [aliased.call("x.id, x.workflow_state", " (id, name, workflow_state)"),
        aliased.call("x.id, x.workflow_state", "")],
       [aliased.call("x.*", " (id, name, workflow_state)"), aliased.call("x.*", "")],
       ["SELECT u.id FROM #{union} u WHERE workflow_state <> 'deleted'",
        "SELECT u.id FROM #{union} u WHERE u.workflow_state <> 'deleted'"]]
    )
  end

  it "refuses a conjunct too deep to deparse" do
    _, literals = literals_for("SELECT 1")
    nested = ->(depth, column) { (1..depth).reduce("#{column} > $1") { |inner, _| "(#{inner} OR false) IS TRUE" } }
    sql = lambda do |depth|
      inner = arm(nested.call(depth, "users.id"))
      "SELECT u.id FROM (#{inner} UNION #{inner}) u WHERE #{nested.call(depth, "u.id")}"
    end

    expect(rule.rewrites(PgQuery.parse(sql.call(150)), catalog, literals)).to eq([])
    expect(rule.rewrites(PgQuery.parse(sql.call(2)), catalog, literals).size).to eq(1)
  end

  it "makes no rewrite without the literals oracle" do
    redacted, = literals_for(
      "SELECT u.id FROM (#{arm("users.id > 1")} UNION #{arm("users.id > 1")}) u WHERE u.id > 1"
    )

    expect(rule.rewrites(PgQuery.parse(redacted), catalog, nil)).to eq([])
  end

  it "doesn't change the parse it was given" do
    redacted, literals = literals_for(
      "SELECT u.id FROM (#{arm("users.id > 1")} UNION #{arm("users.id > 1")}) u WHERE u.id > 1"
    )
    parse = PgQuery.parse(redacted)
    before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

    expect(rule.rewrites(parse, catalog, literals).size).to eq(1)
    expect(parse.tree).to eq(before)
  end
end
