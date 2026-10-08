# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/or_to_union"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' or_to_union, on a real server: what it writes, that its
# output returns the rows its input does (as a multiset, and in order when
# the query is ordered) on data that would show a wrong transformation, and
# that it only fires when the catalog proves a key of every FROM table and
# the shape is one it can split.
RSpec.describe Quaack::Enclave::RewriteRules::OrToUnion do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  after do
    conn.close
    production.drop
  end

  # The rule's rewrites of sql, each as SQL.
  def rewritten(sql)
    rule.rewrites(PgQuery.parse(sql), catalog).map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  # The column names and the rows, sorted unless the query orders them.
  def rows(sql, params, ordered)
    result = conn.exec_params(sql, params)
    [result.fields, ordered ? result.values : result.values.sort_by(&:to_s)]
  end

  # The original's rows, once every rewrite has been checked to return the
  # same rows under the same column names.
  def same_rows(sql, rewrites, params = [], ordered: false)
    expected = rows(sql, params, ordered)
    expect(rewrites).not_to be_empty
    rewrites.each { expect(rows(it, params, ordered)).to eq(expected), "#{it} returns other rows" }
    expected.last
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["or_to_union",
       "An OR whose arms read different tables or subqueries becomes a UNION of one query per arm, which the " \
       "rest of the query reads in place of its tables."]
    )
  end

  # Assignments, each with user 5's submissions unless said:
  #   1  two submissions, each with a participation of user 7's, and in the
  #      list: both arms, and two join rows that give the same output row
  #   2  in the list only
  #   3  one submission with two participations: the first arm only, and
  #      an EXISTS that a join would multiply
  #   4  neither arm: its participation is user 8's
  #   5  in the list and with a participation, but its submission is user 6's
  #   6  two submissions, in the list only: the same output row twice,
  #      from one arm
  #   7  a participation only, and the same title as 3
  # Submission 101's flag is true, 301's false, and the rest NULL.
  context "with assignments, their submissions, and those submissions' participations" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.a (id int PRIMARY KEY, title text, doc json, code text UNIQUE, loose int NOT NULL);
        CREATE TABLE public.s (id int PRIMARY KEY, a_id int, user_id int, flag boolean);
        CREATE TABLE public.cp (id int PRIMARY KEY, s_id int, user_id int);
        CREATE TABLE public.nokey (id int NOT NULL, a_id int);
        CREATE TABLE public.nullkey (id int UNIQUE, a_id int);
        CREATE TABLE public.nndkey (id int, a_id int);
        CREATE UNIQUE INDEX nndkey_id ON public.nndkey (id) NULLS NOT DISTINCT;
        CREATE TABLE public.jsonkey (id jsonb PRIMARY KEY, a_id int);
        CREATE TABLE public."my s" (id int PRIMARY KEY, a_id int);
        CREATE SCHEMA other;
        CREATE TABLE other.a (id int PRIMARY KEY, title text, loose int);
        INSERT INTO public.a VALUES (1, 'one', '{}', 'a', 1), (2, 'two', '{}', 'b', 1), (3, 'same', '{}', NULL, 3),
          (4, 'four', '{}', 'd', 4), (5, 'five', '{}', 'e', 5), (6, 'six', '{}', 'f', 6), (7, 'same', '{}', 'g', 7);
        INSERT INTO public.s VALUES (101, 1, 5, true), (102, 1, 5, NULL), (201, 2, 5, NULL), (301, 3, 5, false),
          (401, 4, 5, NULL), (501, 5, 6, NULL), (601, 6, 5, NULL), (602, 6, 5, NULL), (701, 7, 5, NULL);
        INSERT INTO public.cp VALUES (1, 101, 7), (2, 102, 7), (3, 301, 7), (4, 301, 7), (5, 401, 8), (6, 501, 7),
          (7, 701, 7);
        INSERT INTO public.nokey VALUES (1, 1), (1, 1), (2, 2);
        INSERT INTO public.nullkey VALUES (NULL, 1), (NULL, 1), (2, 2);
        INSERT INTO public.jsonkey VALUES ('1', 1);
        INSERT INTO public."my s" VALUES (1, 1);
      SQL
    end

    let(:from) { "FROM public.a JOIN public.s ON s.a_id = a.id" }
    let(:exists) { "EXISTS (SELECT 1 FROM public.cp WHERE cp.s_id = s.id AND cp.user_id = $2)" }
    let(:where) { "WHERE s.user_id = $1 AND (#{exists} OR a.id IN ($3, $4, $5, $6))" }
    let(:fires) { "SELECT a.id, a.title #{from} #{where}" }
    let(:params) { [5, 7, 1, 2, 5, 6] }

    it "reads a UNION of one query per arm, each with a key of every table, and keeps rows that only look alike" do
      rewrites = rewritten(fires)

      expect(rewrites).to eq(
        ["SELECT arms_1.id_1 AS id, arms_1.title_1 AS title FROM " \
         "(SELECT a.id AS id_1, a.title AS title_1, s.id AS id_2 #{from} WHERE s.user_id = $1 AND #{exists} " \
         "UNION SELECT a.id AS id_1, a.title AS title_1, s.id AS id_2 #{from} " \
         "WHERE s.user_id = $1 AND a.id IN ($3, $4, $5, $6)) arms_1"]
      )
      expect(same_rows(fires, rewrites, params))
        .to eq([%w[1 one], %w[1 one], %w[2 two], %w[3 same], %w[6 six], %w[6 six], %w[7 same]])
    end

    it "states a key of every FROM table unique and not null, in assumption-check's vocabulary" do
      expect(rule.rewrites(PgQuery.parse(fires), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.a", "columns" => ["id"] },
          { "kind" => "not_null", "table" => "public.a", "column" => "id" },
          { "kind" => "unique", "table" => "public.s", "columns" => ["id"] },
          { "kind" => "not_null", "table" => "public.s", "column" => "id" }]]
      )
    end

    it "doesn't change the parse it was given" do
      parse = PgQuery.parse(fires)
      before = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(parse.tree))

      expect(rule.rewrites(parse, catalog).size).to eq(1)
      expect(parse.tree).to eq(before)
    end

    it "would be wrong as a plain UNION of the select list: the rows that look alike would be merged" do
      plain = "SELECT a.id, a.title #{from} WHERE s.user_id = $1 AND #{exists} " \
              "UNION SELECT a.id, a.title #{from} WHERE s.user_id = $1 AND a.id IN ($3, $4, $5, $6)"

      expect([conn.exec_params(plain, params).ntuples, conn.exec_params(fires, params).ntuples]).to eq([5, 7])
    end

    it "keeps a row once when one arm is NULL and the other true, and drops it when neither is true" do
      sql = "SELECT s.id, s.flag #{from} WHERE s.flag OR a.title = $1"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT arms_1.id_1 AS id, arms_1.flag_1 AS flag FROM " \
         "(SELECT s.id AS id_1, s.flag AS flag_1, a.id AS id_2 #{from} WHERE s.flag " \
         "UNION SELECT s.id AS id_1, s.flag AS flag_1, a.id AS id_2 #{from} WHERE a.title = $1) arms_1"]
      )
      expect(same_rows(sql, rewrites, ["one"])).to eq([%w[101 t], ["102", nil]])
      expect(same_rows(sql, rewrites, [nil])).to eq([%w[101 t]])
    end

    it "counts over the UNION, so an aggregate sees each row once" do
      sql = "SELECT count(*), max(a.title) #{from} #{where}"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT count(*), max(arms_1.title_1) FROM " \
         "(SELECT a.title AS title_1, a.id AS id_1, s.id AS id_2 #{from} WHERE s.user_id = $1 AND #{exists} " \
         "UNION SELECT a.title AS title_1, a.id AS id_1, s.id AS id_2 #{from} " \
         "WHERE s.user_id = $1 AND a.id IN ($3, $4, $5, $6)) arms_1"]
      )
      expect(same_rows(sql, rewrites, params)).to eq([%w[7 two]])
    end

    it "orders and limits the whole UNION, by columns the UNION gives" do
      sql = "SELECT a.title AS t, s.id + 1 #{from} #{where} ORDER BY a.title DESC, s.id LIMIT $7 OFFSET 1"

      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT arms_1.title_1 AS t, arms_1.id_1 + 1 FROM " \
         "(SELECT a.title AS title_1, s.id AS id_1, a.id AS id_2 #{from} WHERE s.user_id = $1 AND #{exists} " \
         "UNION SELECT a.title AS title_1, s.id AS id_1, a.id AS id_2 #{from} " \
         "WHERE s.user_id = $1 AND a.id IN ($3, $4, $5, $6)) arms_1 " \
         "ORDER BY arms_1.title_1 DESC, arms_1.id_1 LIMIT $7 OFFSET 1"]
      )
      expect(same_rows(sql, rewrites, params + [5], ordered: true))
        .to eq([%w[six 602], %w[six 603], %w[same 302], %w[same 702], %w[one 102]])
    end

    it "takes a select-list entry with an AS, and one with no column in it, since both keep their names" do
      sql = "SELECT 1, a.id::text AS x, $1::int #{from} WHERE s.flag OR a.loose = 3"

      rewrites = rewritten(sql)

      expect(rewrites.first).to start_with("SELECT 1, arms_1.id_1::text AS x, $1::int FROM (SELECT a.id AS id_1, ")
      expect(same_rows(sql, rewrites, [9])).to eq([%w[1 1 9], %w[1 3 9]])
    end

    it "applies DISTINCT to the whole UNION" do
      sql = "SELECT DISTINCT a.title #{from} #{where} ORDER BY a.title"

      rewrites = rewritten(sql)

      expect(rewrites.first).to start_with("SELECT DISTINCT arms_1.title_1 AS title FROM (SELECT a.title AS title_1,")
      expect(rewrites.first).to end_with("arms_1 ORDER BY arms_1.title_1")
      expect(same_rows(sql, rewrites, params, ordered: true)).to eq([["one"], ["same"], ["six"], ["two"]])
    end

    it "expands name.* into the table's columns, under their own names" do
      sql = "SELECT s.*, a.title #{from} #{where}"

      rewrites = rewritten(sql)

      expect(rewrites.first).to start_with(
        "SELECT arms_1.id_1 AS id, arms_1.a_id_1 AS a_id, arms_1.user_id_1 AS user_id, arms_1.flag_1 AS flag, " \
        "arms_1.title_1 AS title FROM (SELECT s.id AS id_1, s.a_id AS a_id_1, s.user_id AS user_id_1, " \
        "s.flag AS flag_1, a.title AS title_1, a.id AS id_2 FROM"
      )
      expect(same_rows(sql, rewrites, params).map(&:first)).to eq(%w[101 102 201 301 601 602 701])
    end

    it "splits an OR of three arms, and an arm that's an AND" do
      sql = "SELECT a.id #{from} WHERE (s.flag OR (a.loose = 1 AND s.user_id = 5) OR #{exists.sub("$2", "7")})"

      rewrites = rewritten(sql)

      expect(rewrites.first.scan("UNION").size).to eq(2)
      expect(rewrites.first).to include("WHERE s.flag UNION SELECT", "WHERE a.loose = 1 AND s.user_id = 5) UNION")
      expect(same_rows(sql, rewrites)).to eq([["1"], ["1"], ["2"], ["3"], ["5"], ["7"]])
    end

    it "splits an OR of two subqueries, though neither arm reads a table of its own" do
      sql = "SELECT s.id #{from} WHERE #{exists.sub("$2", "7")} OR #{exists.sub("$2", "8")}"

      rewrites = rewritten(sql)

      expect(rewrites.first).to include("cp.user_id = 7) UNION SELECT s.id AS id_1, a.id AS id_2 FROM")
      expect(same_rows(sql, rewrites)).to eq([["101"], ["102"], ["301"], ["401"], ["501"], ["701"]])
    end

    it "reads the same table twice, with a key for each read" do
      sql = "SELECT a.id, b.id FROM public.a, public.a b WHERE a.title = b.title AND (a.loose = 3 OR b.loose = 3)"

      rewrites = rewritten(sql)

      expect(rewrites.first).to include("SELECT a.id AS id_1, b.id AS id_2 FROM public.a, public.a b WHERE")
      expect(same_rows(sql, rewrites)).to eq([%w[3 3], %w[3 7], %w[7 3]])
      expect(rule.rewrites(PgQuery.parse(sql), catalog).first.assumptions.size).to eq(2)
    end

    it "names the UNION apart from the tables it reads" do
      sql = "SELECT arms_1.id FROM public.a arms_1 JOIN public.s ON s.a_id = arms_1.id " \
            "WHERE s.flag OR arms_1.loose = 3"

      rewrites = rewritten(sql)

      expect(rewrites.first).to start_with("SELECT arms_2.id_1 AS id FROM (SELECT arms_1.id AS id_1, s.id AS id_2 ")
      expect(same_rows(sql, rewrites)).to eq([["1"], ["3"]])
    end

    # Postgres would cut each column's name plus _1 to the same 63 bytes.
    it "names the UNION's columns apart when the columns' names are 62 and 63 characters long" do
      long = "x" * 62
      conn.exec(%(CREATE TABLE public.wide (id int PRIMARY KEY, #{long} int, #{long}_ int)))
      conn.exec("INSERT INTO public.wide VALUES (1, 10, 11), (3, 30, 31), (4, 40, 41)")
      sql = "SELECT w.#{long}, w.#{long}_ FROM public.wide w JOIN public.s ON s.a_id = w.id WHERE s.flag OR w.id = 3"

      rewrites = rewritten(sql)

      expect(rewrites.first).to start_with("SELECT arms_1.#{"x" * 61}_1 AS #{long}, arms_1.#{"x" * 61}_2 AS #{long}_ ")
      expect(same_rows(sql, rewrites)).to eq([%w[10 11], %w[30 31]])
    end

    it "splits the OR that key_in_self_join makes of an IN over a UNION ALL, when the generator chains them" do
      sql = "SELECT count(*) #{from} WHERE a.id IN (SELECT a2.id FROM public.a a2 JOIN public.s s2 " \
            "ON s2.a_id = a2.id JOIN public.cp ON cp.s_id = s2.id WHERE cp.user_id = 7 UNION ALL " \
            "SELECT a3.id FROM public.a a3 WHERE a3.id IN (2, 6)) AND s.user_id = 5"

      generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(sql), catalog)

      expect(generated.rewrites.map { |rewrite| rewrite.rules.map(&:name) })
        .to eq([%w[key_in_self_join], %w[key_in_self_join or_to_union]])
      expect(generated.rewrites.last.sql).to start_with("SELECT count(*) FROM (SELECT a.id AS id_1, s.id AS id_2 FROM")
      expect(generated.rewrites.last.assumptions.map { [it["kind"], it["table"]] }).to eq(
        [%w[unique public.a], %w[not_null public.a], %w[unique public.s], %w[not_null public.s]]
      )
      expect(same_rows(sql, generated.rewrites.map(&:sql))).to eq([["7"]])
    end

    it "gives one rewrite per OR it can split" do
      sql = "SELECT a.id #{from} WHERE (s.flag OR a.loose = 3) AND (s.user_id = 5 OR a.title = 'x')"

      rewrites = rewritten(sql)

      expect(rewrites.size).to eq(2)
      expect(rewrites.first).to include("WHERE s.flag AND (s.user_id = 5 OR a.title = 'x') UNION")
      expect(rewrites.last).to include("WHERE (s.flag OR a.loose = 3) AND s.user_id = 5 UNION")
      expect(same_rows(sql, rewrites)).to eq([["1"], ["3"]])
    end

    # Each is a query that fires, changed in one way that makes it unsafe,
    # unproven, or not worth splitting. FROM_ stands for the join above.
    {
      "both arms read the same one table" => "SELECT a.id, a.title FROM_ WHERE a.loose = 1 OR a.title = 'x'",
      "an arm reads no table" => "SELECT a.id, a.title FROM_ WHERE s.flag OR $1",
      "the OR is under a NOT" => "SELECT a.id, a.title FROM_ WHERE NOT (s.flag OR a.loose = 3)",
      "the OR is under another OR, whose own arms read the same tables" =>
        "SELECT a.id, a.title FROM_ WHERE (s.flag AND a.loose = 2) OR (a.loose = 3 AND (s.flag OR a.loose = 3))",
      "the OR is in a join's ON" =>
        "SELECT a.id, a.title FROM public.a JOIN public.s ON s.a_id = a.id AND (s.flag OR a.loose = 3)",
      "the OR is in a subquery" =>
        "SELECT a.id, a.title FROM public.a WHERE EXISTS " \
        "(SELECT 1 FROM public.s JOIN public.cp ON cp.s_id = s.id WHERE s.a_id = a.id AND (s.flag OR cp.user_id = 7))",
      "it's a NOT of a subquery, not an OR" =>
        "SELECT a.id, a.title FROM_ WHERE NOT EXISTS (SELECT 1 FROM public.cp WHERE cp.s_id = s.id)",
      "an arm has only an unqualified column" => "SELECT a.id, a.title FROM_ WHERE flag OR a.loose = 3",
      "an arm has an unqualified column among others" =>
        "SELECT a.id, a.title FROM_ WHERE (flag AND s.user_id = 5) OR a.loose = 3",
      "an arm has a whole-row reference" =>
        "SELECT a.id, a.title FROM_ WHERE (s.* IS NOT NULL AND s.flag) OR a.loose = 3",
      "a table has no unique key" =>
        "SELECT a.id FROM public.a JOIN public.nokey s ON s.a_id = a.id WHERE s.id = 1 OR a.loose = 3",
      "a table's only unique key is nullable" =>
        "SELECT a.id FROM public.a JOIN public.nullkey s ON s.a_id = a.id WHERE s.id IS NULL OR a.loose = 3",
      "a table's only unique key is NULLS NOT DISTINCT, but nullable" =>
        "SELECT a.id FROM public.a JOIN public.nndkey s ON s.a_id = a.id WHERE s.id IS NULL OR a.loose = 3",
      "a table's only key is of a type the rule doesn't know UNION compares" =>
        "SELECT a.id FROM public.a JOIN public.jsonkey s ON s.a_id = a.id WHERE s.a_id = 1 OR a.loose = 3",
      "an assumption can't name a table" =>
        %(SELECT a.id FROM public.a JOIN public."my s" s ON s.a_id = a.id WHERE s.id = 1 OR a.loose = 3),
      "the select list has a column UNION can't compare" => "SELECT a.id, a.doc FROM_ WHERE s.flag OR a.loose = 3",
      "name.* has a column UNION can't compare" => "SELECT a.* FROM_ WHERE s.flag OR a.loose = 3",
      "the select list is *" => "SELECT * FROM_ WHERE s.flag OR a.loose = 3",
      "the select list has an unqualified column" => "SELECT title FROM_ WHERE s.flag OR a.loose = 3",
      "the select list has a system column" => "SELECT a.ctid FROM_ WHERE s.flag OR a.loose = 3",
      "the select list has a subquery" =>
        "SELECT a.id, (SELECT count(*) FROM public.cp WHERE cp.s_id = s.id) FROM_ WHERE s.flag OR a.loose = 3",
      "the select list has a subquery that reads a table by a name the FROM has" =>
        "SELECT a.id, (SELECT count(*) FROM public.cp s WHERE s.id = a.id) AS n FROM_ WHERE s.flag OR a.loose = 3",
      "an unnamed select-list expression takes its name from its column" =>
        "SELECT a.id::text FROM_ WHERE s.flag OR a.loose = 3",
      "it has GROUP BY" => "SELECT a.id, count(*) FROM_ WHERE s.flag OR a.loose = 3 GROUP BY a.id",
      "it has HAVING" => "SELECT count(*) FROM_ WHERE s.flag OR a.loose = 3 HAVING count(*) > 0",
      "it has a window function" => "SELECT a.id, row_number() OVER (ORDER BY s.id) FROM_ WHERE s.flag OR a.loose = 3",
      "it has a WINDOW clause" => "SELECT a.id FROM_ WHERE s.flag OR a.loose = 3 WINDOW w AS (ORDER BY s.id)",
      "it has DISTINCT ON" => "SELECT DISTINCT ON (a.id) a.id FROM_ WHERE s.flag OR a.loose = 3 ORDER BY a.id",
      "it orders by an output name" => "SELECT a.id AS x FROM_ WHERE s.flag OR a.loose = 3 ORDER BY x",
      "it orders by a subquery" =>
        "SELECT a.id FROM_ WHERE s.flag OR a.loose = 3 ORDER BY (SELECT count(*) FROM public.cp s WHERE s.id = a.id)",
      "it locks rows" => "SELECT a.id, a.title FROM_ WHERE s.flag OR a.loose = 3 FOR UPDATE",
      "it has a WITH" => "WITH w AS (SELECT 1) SELECT a.id, a.title FROM_ WHERE s.flag OR a.loose = 3",
      "it's SELECT INTO" => "SELECT a.id, a.title INTO public.made FROM_ WHERE s.flag OR a.loose = 3",
      "it's a UNION already" =>
        "SELECT a.id, a.title FROM_ WHERE s.flag OR a.loose = 3 UNION ALL SELECT a.id, a.title FROM public.a",
      "it has no FROM" =>
        "SELECT 1 WHERE EXISTS (SELECT 1 FROM public.a WHERE a.loose = 3) " \
        "OR EXISTS (SELECT 1 FROM public.s WHERE s.flag)",
      "it has an outer join" =>
        "SELECT a.id, a.title FROM public.a LEFT JOIN public.s ON s.a_id = a.id WHERE s.flag OR a.loose = 3",
      "it has a NATURAL JOIN" =>
        "SELECT a.id, a.title FROM public.a NATURAL JOIN public.s WHERE s.flag OR a.loose = 3",
      "it has JOIN USING" =>
        "SELECT a.id, a.title FROM public.a JOIN public.s USING (id) WHERE s.flag OR a.loose = 3",
      "its join has an alias" =>
        "SELECT j.id FROM (public.a JOIN public.s ON s.a_id = a.id) j WHERE j.flag OR j.loose = 3",
      "it reads a subquery" =>
        "SELECT a.id FROM public.a JOIN (SELECT * FROM public.s) s ON s.a_id = a.id WHERE s.flag OR a.loose = 3",
      "it reads a function" =>
        "SELECT a.id FROM public.a, generate_series(1, 2) s WHERE s.s = 1 OR a.loose = 3",
      "it reads a CTE" =>
        "WITH s AS (SELECT * FROM public.s) SELECT a.id FROM public.a JOIN s ON s.a_id = a.id " \
        "WHERE s.flag OR a.loose = 3",
      "it reads a table with ONLY" =>
        "SELECT a.id FROM public.a JOIN ONLY public.s ON s.a_id = a.id WHERE s.flag OR a.loose = 3",
      "a table's alias renames columns" =>
        "SELECT a.id FROM public.a JOIN public.s s (id, a_id) ON s.a_id = a.id WHERE s.flag OR a.loose = 3",
      "two tables are read by one name" =>
        "SELECT s.id FROM public.s, public.a, other.a WHERE s.flag OR a.loose = 3",
      # An arm that can raise on some rows (task 20261002-5).
      "an arm casts a column" => "SELECT a.id FROM_ WHERE s.flag OR a.title::int = 3",
      "an arm divides by a column" => "SELECT a.id FROM_ WHERE s.flag OR 6 / a.loose = 3",
      "an arm compares with a modulo of a column" => "SELECT a.id FROM_ WHERE s.flag OR a.loose = 6 % a.id",
      "an arm calls a function on a column" => "SELECT a.id FROM_ WHERE s.flag OR length(a.title) = 3",
      "an arm matches a column with a regular expression" => "SELECT a.id FROM_ WHERE s.flag OR a.title ~ a.code",
      "an arm has a scalar subquery" =>
        "SELECT a.id FROM_ WHERE s.flag OR a.loose = (SELECT cp.user_id FROM public.cp WHERE cp.s_id = s.id)",
      "an arm's subquery casts a column" =>
        "SELECT a.id FROM_ WHERE s.flag OR EXISTS (SELECT 1 FROM public.cp WHERE cp.s_id::text = '1')",
      "an arm's LIKE pattern is NULL" => "SELECT a.id FROM_ WHERE s.flag OR a.title LIKE NULL",
      "an arm uses an operator from a schema, though its schema is named like a comparison" =>
        'SELECT a.id FROM_ WHERE s.flag OR a.loose OPERATOR("=".=) 3'
    }.each do |why, sql|
      it "doesn't fire when #{why}" do
        expect(rewritten("SELECT a.id, a.title #{from} WHERE s.flag OR a.loose = 3").size).to eq(1)
        expect(rewritten(sql.sub("FROM_", from))).to eq([])
      end
    end

    it "would be wrong on the keys it refuses: a UNION on them merges rows the original returns twice" do
      [["nokey", "s.id = 1"], ["nullkey", "s.id IS NULL"]].each do |table, arm|
        from = "FROM public.a JOIN public.#{table} s ON s.a_id = a.id"
        union = "SELECT u.x FROM (SELECT a.id AS x, s.id AS y #{from} WHERE #{arm} " \
                "UNION SELECT a.id AS x, s.id AS y #{from} WHERE a.loose = 1) u"

        expect([conn.exec("SELECT a.id #{from} WHERE #{arm} OR a.loose = 1").ntuples, conn.exec(union).ntuples])
          .to eq([3, 2])
      end
    end
  end

  # Tables whose only keys have several columns (task 20261008-6). Each
  # joins to a, whose row 1 has loose 1. pair's rows (1, 1) and (1, 2)
  # both join to a's row 1 and give the same select list, so only a UNION
  # that carries the whole key keeps them apart. pair's row (3, 5) has a
  # NULL note.
  context "with tables whose keys have several columns" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.a (id int PRIMARY KEY, loose int NOT NULL);
        CREATE TABLE public.pair (a_id int, n int, note text, PRIMARY KEY (a_id, n));
        CREATE TABLE public.triple (a_id int NOT NULL, n int NOT NULL, m int NOT NULL, x int NOT NULL,
          UNIQUE (a_id, n, m), UNIQUE (a_id, x));
        CREATE TABLE public.single (id int NOT NULL UNIQUE, a_id int, n int, PRIMARY KEY (a_id, n));
        CREATE TABLE public.pairnull (a_id int NOT NULL, n int, UNIQUE (a_id, n));
        CREATE TABLE public.pairnnd (a_id int NOT NULL, n int, UNIQUE NULLS NOT DISTINCT (a_id, n));
        CREATE TABLE public.pairjson (a_id int, d jsonb, PRIMARY KEY (a_id, d));
        CREATE TABLE public.pairpartial (a_id int NOT NULL, n int NOT NULL);
        CREATE UNIQUE INDEX pairpartial_key ON public.pairpartial (a_id, n) WHERE n > 0;
        INSERT INTO public.a VALUES (1, 1), (2, 2), (3, 3);
        INSERT INTO public.pair VALUES (1, 1, 'x'), (1, 2, 'x'), (2, 1, 'y'), (3, 5, NULL);
        INSERT INTO public.triple VALUES (1, 1, 1, 1), (1, 1, 2, 2), (2, 1, 1, 1);
        INSERT INTO public.single VALUES (1, 1, 1), (2, 1, 2), (3, 2, 1);
        INSERT INTO public.pairnull VALUES (1, NULL), (1, NULL), (2, 1);
        INSERT INTO public.pairjson VALUES (1, '1'), (1, '2');
        INSERT INTO public.pairpartial VALUES (1, 1), (1, 2);
      SQL
    end

    let(:sql) { "SELECT a.id, s.note FROM public.a JOIN public.pair s ON s.a_id = a.id WHERE s.n = 1 OR a.loose = 1" }

    it "carries every column of the key through each arm, and keeps rows that differ only in the key" do
      rewrites = rewritten(sql)

      expect(rewrites).to eq(
        ["SELECT arms_1.id_1 AS id, arms_1.note_1 AS note FROM " \
         "(SELECT a.id AS id_1, s.note AS note_1, s.a_id AS a_id_1, s.n AS n_1 " \
         "FROM public.a JOIN public.pair s ON s.a_id = a.id WHERE s.n = 1 " \
         "UNION SELECT a.id AS id_1, s.note AS note_1, s.a_id AS a_id_1, s.n AS n_1 " \
         "FROM public.a JOIN public.pair s ON s.a_id = a.id WHERE a.loose = 1) arms_1"]
      )
      expect(same_rows(sql, rewrites)).to eq([%w[1 x], %w[1 x], %w[2 y]])
    end

    it "states the whole key unique and each of its columns not null" do
      expect(rule.rewrites(PgQuery.parse(sql), catalog).map(&:assumptions)).to eq(
        [[{ "kind" => "unique", "table" => "public.a", "columns" => ["id"] },
          { "kind" => "not_null", "table" => "public.a", "column" => "id" },
          { "kind" => "unique", "table" => "public.pair", "columns" => %w[a_id n] },
          { "kind" => "not_null", "table" => "public.pair", "column" => "a_id" },
          { "kind" => "not_null", "table" => "public.pair", "column" => "n" }]]
      )
    end

    it "would be wrong carrying only part of the key: the UNION merges rows the original returns twice" do
      from = "FROM public.a JOIN public.pair s ON s.a_id = a.id"
      partial = "SELECT u.x FROM (SELECT a.id AS x, s.a_id AS y #{from} WHERE s.n = 1 " \
                "UNION SELECT a.id AS x, s.a_id AS y #{from} WHERE a.loose = 1) u"

      expect([conn.exec(sql).ntuples, conn.exec(partial).ntuples]).to eq([3, 2])
    end

    it "keeps a row once when one arm is NULL and the other true, and drops it when neither is true" do
      nulls = "SELECT a.id FROM public.a JOIN public.pair s ON s.a_id = a.id WHERE s.note <> 'x' OR a.loose = 1"

      expect(same_rows(nulls, rewritten(nulls))).to eq([["1"], ["1"], ["2"]])
    end

    it "prefers a key of fewer columns, and a one-column key over any other" do
      triple = "SELECT a.id FROM public.a JOIN public.triple s ON s.a_id = a.id WHERE s.n = 1 OR a.loose = 1"
      single = "SELECT a.id FROM public.a JOIN public.single s ON s.a_id = a.id WHERE s.n = 1 OR a.loose = 1"

      expect(rewritten(triple).first).to include("SELECT a.id AS id_1, s.a_id AS a_id_1, s.x AS x_1 FROM")
      expect(same_rows(triple, rewritten(triple))).to eq([["1"], ["1"], ["2"]])
      expect(rewritten(single).first).to include("SELECT a.id AS id_1, s.id AS id_2 FROM")
      expect(same_rows(single, rewritten(single))).to eq([["1"], ["1"], ["2"]])
    end

    {
      "a column of the only key is nullable" => "pairnull",
      "a column of the only key is nullable, though the key is NULLS NOT DISTINCT" => "pairnnd",
      "a column of the only key is of a type the rule doesn't know UNION compares" => "pairjson",
      "the only key's index is partial" => "pairpartial"
    }.each do |why, table|
      it "doesn't fire when #{why}" do
        expect(rewritten(sql).size).to eq(1)
        expect(rewritten("SELECT a.id FROM public.a JOIN public.#{table} s ON s.a_id = a.id " \
                         "WHERE s.a_id = 2 OR a.loose = 1")).to eq([])
      end
    end

    it "would be wrong on a nullable key: a UNION on it merges rows the original returns twice" do
      from = "FROM public.a JOIN public.pairnull s ON s.a_id = a.id"
      union = "SELECT u.x FROM (SELECT a.id AS x, s.a_id AS y, s.n AS z #{from} WHERE s.n IS NULL " \
              "UNION SELECT a.id AS x, s.a_id AS y, s.n AS z #{from} WHERE a.loose = 1) u"

      expect([conn.exec("SELECT a.id #{from} WHERE s.n IS NULL OR a.loose = 1").ntuples, conn.exec(union).ntuples])
        .to eq([2, 1])
    end
  end

  # Postgres runs an OR's arms left to right and stops at the first true
  # one, so an earlier arm can guard a later one that would raise. Split,
  # every arm runs on its own rows, and the guarded one raises (task
  # 20261002-5). Order 1 is 'n' kind, a VIP, and its item's qty is 0, its
  # val isn't a number, its pat is a LIKE pattern that ends in the escape
  # character, and its big doesn't fit an int. Order 2's item is ordinary.
  context "with orders and their items, where an arm guards another" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.o (id int PRIMARY KEY, vip boolean NOT NULL, kind text NOT NULL);
        CREATE TABLE public.i (id int PRIMARY KEY, order_id int NOT NULL, qty int NOT NULL, total int NOT NULL,
                               val text NOT NULL, pat text NOT NULL, big bigint NOT NULL);
        INSERT INTO public.o VALUES (1, true, 'n'), (2, false, 'm');
        INSERT INTO public.i VALUES (10, 1, 0, 50, 'abc', 'ab\\', 3000000000), (20, 2, 1, 50, '9', '%', 1);
      SQL
    end

    let(:from) { "FROM public.o JOIN public.i ON i.order_id = o.id" }

    {
      "a cast" => "o.kind = 'n' OR i.val::int > 5",
      "a division" => "o.vip OR i.total / i.qty > 10",
      "a division guarded by an arm on its own table" => "i.qty = 0 OR i.total / i.qty > 10 OR o.vip",
      "a LIKE whose pattern is a column" => "o.vip OR i.val LIKE i.pat",
      "an ILIKE whose pattern is a column" => "o.vip OR i.val ILIKE i.pat",
      "a NOT LIKE whose pattern is a constant that ends in the escape character" =>
        "o.vip OR o.kind = 'm' OR i.val NOT LIKE 'ab\\'",
      "an index into a value by a column" => "o.vip OR (ARRAY[1, 2])[i.big] = 1"
    }.each do |what, where|
      it "refuses an OR with #{what} an earlier arm guards, which the original runs" do
        sql = "SELECT o.id, i.id AS item #{from} WHERE #{where}"

        expect(conn.exec(sql).values.sort).to eq([%w[1 10], %w[2 20]])
        expect(rewritten(sql)).to eq([])
      end
    end

    it "still splits an OR with no such arm, and a cast with no column in it" do
      sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.total > '10'::int"

      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 10], %w[2 20]])
    end

    it "would be wrong on a LIKE whose pattern is a column: the arm, run on its own, raises" do
      expect { conn.exec("SELECT o.id #{from} WHERE i.val LIKE i.pat") }
        .to raise_error(PG::InvalidEscapeSequence, /LIKE pattern must not end with escape character/)
    end

    it "still splits an OR with a LIKE or ILIKE whose pattern is a constant that doesn't end in the escape character" do
      sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.val LIKE '9%' OR i.val ILIKE 'Z\\\\'"

      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 10], %w[2 20]])
    end

    # The user's decision for task 20261007-52: a parameter pattern is
    # allowed, though the rule can't see its value.
    it "splits an OR with a LIKE or ILIKE whose pattern is a parameter, and returns the same rows" do
      %w[LIKE ILIKE].each do |like|
        sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.val #{like} $1"

        expect(same_rows(sql, rewritten(sql), ["9%"])).to eq([%w[1 10], %w[2 20]])
      end
    end

    # The risk docs/transforms/or_to_union.md and DESIGN.md state for a
    # parameter pattern: one that ends in a lone backslash raises in the
    # rewrite, where the original's other arms skip the LIKE.
    it "raises in the rewrite, where the original returns rows, when a parameter pattern ends in a lone backslash" do
      sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR o.kind = 'm' OR i.val LIKE $1"
      rewrites = rewritten(sql)

      expect(conn.exec_params(sql, ["ab\\"]).values.sort).to eq([%w[1 10], %w[2 20]])
      expect(rewrites.size).to eq(1)
      expect { conn.exec_params(rewrites.first, ["ab\\"]) }
        .to raise_error(PG::InvalidEscapeSequence, /LIKE pattern must not end with escape character/)
    end

    # With standard_conforming_strings off, the server reads 'ab\\' as ab
    # and one backslash, while pg_query reads two (task 20261007-52).
    context "with standard_conforming_strings off" do
      before { conn.exec("SET standard_conforming_strings = off; SET escape_string_warning = off") }

      let(:pattern) { "'ab\\\\'" }

      it "refuses an OR with a LIKE whose constant pattern has a backslash" do
        sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR o.kind = 'm' OR i.val LIKE #{pattern}"

        expect(conn.exec(sql).values.sort).to eq([%w[1 10], %w[2 20]])
        expect(rewritten(sql)).to eq([])
      end

      it "would be wrong there: the arm, run on its own, raises" do
        expect { conn.exec("SELECT o.id #{from} WHERE i.val LIKE #{pattern}") }
          .to raise_error(PG::InvalidEscapeSequence, /LIKE pattern must not end with escape character/)
      end

      it "still splits an OR with a LIKE whose pattern is a constant with no backslash, or a parameter" do
        sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.val LIKE '9%' OR i.val ILIKE $1"

        expect(same_rows(sql, rewritten(sql), ["z"])).to eq([%w[1 10], %w[2 20]])
      end
    end

    # ILIKE raises on a nondeterministic collation, and so does Postgres
    # 17's LIKE, only as it reads a row (task 20261007-52).
    context "when a column uses a nondeterministic collation" do
      before do
        conn.exec(<<~SQL)
          CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
          ALTER TABLE public.i ADD COLUMN v text COLLATE public.loose NOT NULL DEFAULT 'x';
        SQL
      end

      it "refuses an OR with a LIKE or ILIKE" do
        %w[LIKE ILIKE].each do |like|
          sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR o.kind = 'm' OR i.v #{like} 'x'"

          expect(rewritten(sql)).to eq([]), like
        end
      end

      it "would be wrong on an ILIKE: the original returns rows, and the arm, run on its own, raises" do
        expect(conn.exec("SELECT o.id #{from} WHERE o.vip OR o.kind = 'm' OR i.v ILIKE 'x'").ntuples).to eq(2)
        expect { conn.exec("SELECT o.id #{from} WHERE i.v ILIKE 'x'") }
          .to raise_error(PG::FeatureNotSupported, /nondeterministic collations are not supported for ILIKE/)
      end
    end

    # pg_attribute keeps a dropped column's collation (task 20261008-11).
    it "still splits an OR with a LIKE when only a dropped column used a nondeterministic collation" do
      conn.exec(<<~SQL)
        CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
        ALTER TABLE public.i ADD COLUMN v text COLLATE public.loose;
        ALTER TABLE public.i DROP COLUMN v;
      SQL
      sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.val LIKE '9%'"

      expect(same_rows(sql, rewritten(sql))).to eq([%w[1 10], %w[2 20]])
    end

    # A domain or a range can carry a nondeterministic collation that no
    # column names directly (task 20261008-11).
    {
      "domain" => "CREATE DOMAIN public.loose_text AS text COLLATE public.loose",
      "range" => "CREATE TYPE public.loose_range AS RANGE (subtype = text, collation = public.loose)"
    }.each do |kind, create|
      it "refuses an OR with a LIKE when a #{kind} uses a nondeterministic collation" do
        conn.exec(<<~SQL)
          CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
          #{create};
        SQL
        sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR o.kind = 'm' OR i.val LIKE 'x'"

        expect(rewritten(sql)).to eq([])
      end
    end

    it "refuses an OR with a LIKE or ILIKE whose column is given a collation" do
      %w[LIKE ILIKE].each do |like|
        sql = "SELECT o.id, i.id AS item #{from} WHERE o.vip OR i.val COLLATE \"C\" #{like} 'x'"

        expect(rewritten(sql.sub(' COLLATE "C"', ""))).not_to be_empty
        expect(rewritten(sql)).to eq([]), like
      end
    end

    it "keeps the arms that read the same table together in one branch" do
      sql = "SELECT o.id #{from} WHERE i.qty = 0 OR i.val = '9' OR o.kind = 'x'"

      rewrites = rewritten(sql)

      expect(rewrites.size).to eq(1)
      expect(rewrites.first.scan(" UNION ").size).to eq(1)
      expect(rewrites.first).to include("WHERE i.qty = 0 OR i.val = '9' UNION")
      expect(same_rows(sql, rewrites)).to eq([["1"], ["2"]])
    end
  end
end
