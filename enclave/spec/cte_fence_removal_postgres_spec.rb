# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/rewrite_rules/cte_fence_removal"
require "quaack/enclave/rewrite_rules/literals"
require_relative "support/production_server"

# DESIGN.md's rewrite-rules' cte_fence_removal, on a real server: a CTE
# Postgres would store, because it's MATERIALIZED or read more than once,
# becomes NOT MATERIALIZED, and every rewrite returns the original's rows.
RSpec.describe Quaack::Enclave::RewriteRules::CteFenceRemoval do
  subject(:rule) { described_class.new }

  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }
  let(:catalog) { Quaack::Enclave::RewriteRules::Catalog.new(conn) }

  # A body that joins users, which drops orders 5 and 6, the only ones
  # with qty 0. A reader's total / qty never divides by zero on its rows,
  # but does on the table's.
  let(:matched) do
    "WITH matched AS MATERIALIZED (SELECT orders.id, orders.user_id, orders.total, orders.qty " \
      "FROM public.orders JOIN public.users ON users.id = orders.user_id)"
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.users (id int PRIMARY KEY, name text, workflow_state text);
      CREATE TABLE public.orders (id int PRIMARY KEY, user_id int, total int, qty int, state text);
      INSERT INTO public.users VALUES (1, 'a', 'active'), (2, 'b', 'deleted'), (3, NULL, 'active');
      INSERT INTO public.orders VALUES
        (1, 1, 10, 2, 'paid'), (2, 1, 30, 3, 'paid'), (3, 2, 5, 5, 'open'), (4, 3, 8, 1, 'paid'),
        (5, 9, 7, 0, 'paid'), (6, NULL, 4, 0, 'open'), (7, 2, 12, 4, 'paid'), (8, 3, 20, 2, 'open');
      ANALYZE public.users, public.orders;
    SQL
  end

  after do
    conn.close
    production.drop
  end

  def redacted(sql) = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))

  # The SQL of each rewrite of sql, each of which states no assumptions.
  def rewritten(sql)
    made = made(redacted(sql))
    expect(made.map(&:assumptions)).to all(eq([]))
    made.map { Quaack::Enclave::Deparse.faithfully(it.tree) }
  end

  def made(redacted)
    literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)
    rule.rewrites(PgQuery.parse(redacted.sql), catalog, literals)
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

  # The rewrites of sql are exactly expected, and each returns sql's rows,
  # which aren't empty.
  def expect_rewrites(sql, *expected)
    expect(rewritten(sql)).to eq(expected)
    expect_same_rows(redacted(sql), expected)
  end

  def expect_same_rows(original, rewrites)
    want = rows(original.sql, original.placeholder_map)
    expect(want).not_to be_empty
    expect(rewrites.map { rows(it, original.placeholder_map) }).to all(eq(want))
  end

  # sql runs, but raises division_by_zero once its CTE is NOT MATERIALIZED,
  # so the rule must leave it alone.
  def expect_raises_unfenced(sql)
    expect(conn.exec(sql).ntuples).to be_positive
    expect { conn.exec(sql.sub("AS MATERIALIZED", "AS NOT MATERIALIZED")) }
      .to raise_error(PG::DivisionByZero)
  end

  it "has a name and a description that are QUAACK's own constants" do
    expect([rule.name, rule.description]).to eq(
      ["cte_fence_removal",
       "A CTE written AS MATERIALIZED, or one the query reads more than once, becomes AS NOT MATERIALIZED, so " \
       "the planner can push each reader's conditions into it."]
    )
  end

  describe "a CTE Postgres would store" do
    it "makes a MATERIALIZED CTE that the query reads once NOT MATERIALIZED" do
      expect_rewrites(
        "WITH recent AS MATERIALIZED (SELECT orders.id, orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = 'paid') SELECT recent.id, recent.total FROM recent WHERE recent.user_id = 1",
        "WITH recent AS NOT MATERIALIZED (SELECT orders.id, orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = $1) SELECT recent.id, recent.total FROM recent WHERE recent.user_id = $2"
      )
    end

    it "makes a plain CTE that two UNION ALL arms read NOT MATERIALIZED, aggregates in the arms and all" do
      expect_rewrites(
        "WITH o AS (SELECT orders.user_id, orders.total FROM public.orders) " \
        "SELECT 'first' AS who, count(*) AS n, sum(o.total) AS total FROM o WHERE o.user_id = 1 " \
        "UNION ALL SELECT 'second', count(*), sum(o.total) FROM o WHERE o.user_id = 2",
        "WITH o AS NOT MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders) " \
        "SELECT $1 AS who, count(*) AS n, sum(o.total) AS total FROM o WHERE o.user_id = $2 " \
        "UNION ALL SELECT $3, count(*), sum(o.total) FROM o WHERE o.user_id = $4"
      )
    end

    it "gives one rewrite per CTE, each changing only that CTE" do
      expect_rewrites(
        "WITH paid AS MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = 'paid'), named AS (SELECT users.id, users.name FROM public.users) " \
        "SELECT a.name, paid.total FROM paid JOIN named a ON a.id = paid.user_id JOIN named b ON b.id = a.id",
        "WITH paid AS NOT MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = $1), named AS (SELECT users.id, users.name FROM public.users) " \
        "SELECT a.name, paid.total FROM paid JOIN named a ON a.id = paid.user_id JOIN named b ON b.id = a.id",
        "WITH paid AS MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = $1), named AS NOT MATERIALIZED (SELECT users.id, users.name FROM public.users) " \
        "SELECT a.name, paid.total FROM paid JOIN named a ON a.id = paid.user_id JOIN named b ON b.id = a.id"
      )
    end

    it "rewrites a CTE in a subquery's WITH" do
      expect_rewrites(
        "SELECT users.id FROM public.users WHERE users.id IN (WITH paid AS MATERIALIZED " \
        "(SELECT orders.user_id FROM public.orders WHERE orders.state = 'paid') " \
        "SELECT paid.user_id FROM paid WHERE paid.user_id > 1)",
        "SELECT users.id FROM public.users WHERE users.id IN (WITH paid AS NOT MATERIALIZED " \
        "(SELECT orders.user_id FROM public.orders WHERE orders.state = $1) " \
        "SELECT paid.user_id FROM paid WHERE paid.user_id > $2)"
      )
    end

    it "rewrites a MATERIALIZED CTE that groups, when the query reads it once" do
      expect_rewrites(
        "WITH totals AS MATERIALIZED (SELECT orders.user_id, sum(orders.total) AS total, count(*) AS n " \
        "FROM public.orders GROUP BY orders.user_id) SELECT totals.total FROM totals WHERE totals.user_id = 1",
        "WITH totals AS NOT MATERIALIZED (SELECT orders.user_id, sum(orders.total) AS total, count(*) AS n " \
        "FROM public.orders GROUP BY orders.user_id) SELECT totals.total FROM totals WHERE totals.user_id = $1"
      )
    end

    it "keeps a reader whose condition can raise only on another table's columns" do
      expect_rewrites(
        "WITH paid AS MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = 'paid') SELECT users.name, paid.total FROM paid " \
        "JOIN public.users ON users.id = paid.user_id WHERE lower(users.name) = 'a'",
        "WITH paid AS NOT MATERIALIZED (SELECT orders.user_id, orders.total FROM public.orders " \
        "WHERE orders.state = $1) SELECT users.name, paid.total FROM paid " \
        "JOIN public.users ON users.id = paid.user_id WHERE lower(users.name) = $2"
      )
    end

    it "keeps a reader whose expression that can raise is inside an aggregate, which runs on the CTE's rows" do
      expect_rewrites(
        "#{matched} SELECT matched.user_id FROM matched GROUP BY matched.user_id " \
        "HAVING sum(matched.total / matched.qty) > 3",
        "#{matched.sub("AS MATERIALIZED", "AS NOT MATERIALIZED")} SELECT matched.user_id FROM matched " \
        "GROUP BY matched.user_id HAVING sum(matched.total / matched.qty) > $1"
      )
    end

    it "keeps an expression that can raise in the query's select list, which runs only on the rows it returns" do
      ratio = "SELECT matched.total / matched.qty AS ratio FROM matched WHERE matched.user_id = "
      expect_rewrites(
        "#{matched} #{ratio}1 UNION ALL #{ratio}2",
        "#{matched.sub("AS MATERIALIZED", "AS NOT MATERIALIZED")} #{ratio}$1 UNION ALL #{ratio}$2"
      )
    end

    it "keeps a window call's arguments that can raise, since they run on the CTE's rows" do
      expect_rewrites(
        "#{matched} SELECT s.id FROM (SELECT matched.id, lag(matched.total / matched.qty) " \
        "OVER (PARTITION BY matched.user_id ORDER BY matched.id) AS r FROM matched) s WHERE s.r > 3",
        "#{matched.sub("AS MATERIALIZED", "AS NOT MATERIALIZED")} SELECT s.id FROM (SELECT matched.id, " \
        "lag(matched.total / matched.qty) OVER (PARTITION BY matched.user_id ORDER BY matched.id) AS r " \
        "FROM matched) s WHERE s.r > $1"
      )
    end

    it "keeps a condition of the body's own that can raise, which runs on the same rows inlined or not" do
      expect_rewrites(
        "WITH paid AS MATERIALIZED (SELECT o.user_id FROM (SELECT orders.user_id, orders.state " \
        "FROM public.orders) o WHERE lower(o.state) = 'paid') SELECT paid.user_id FROM paid WHERE paid.user_id = 1",
        "WITH paid AS NOT MATERIALIZED (SELECT o.user_id FROM (SELECT orders.user_id, orders.state " \
        "FROM public.orders) o WHERE lower(o.state) = $1) SELECT paid.user_id FROM paid WHERE paid.user_id = $2"
      )
    end
  end

  describe "a CTE Postgres doesn't store" do
    it "leaves a plain CTE that the query reads once" do
      expect(rewritten("WITH paid AS (SELECT orders.user_id FROM public.orders WHERE orders.state = 'paid') " \
                       "SELECT paid.user_id FROM paid WHERE paid.user_id = 1")).to eq([])
    end

    it "leaves a CTE that's already NOT MATERIALIZED" do
      expect(rewritten("WITH paid AS NOT MATERIALIZED (SELECT orders.user_id FROM public.orders) " \
                       "SELECT a.user_id FROM paid a JOIN paid b ON b.user_id = a.user_id")).to eq([])
    end

    it "leaves a MATERIALIZED CTE that the query never reads" do
      expect(rewritten("WITH unused AS MATERIALIZED (SELECT orders.user_id FROM public.orders) " \
                       "SELECT users.id FROM public.users WHERE users.id = 1")).to eq([])
    end
  end

  describe "refusals" do
    let(:paid) { "paid AS MATERIALIZED (SELECT orders.user_id FROM public.orders WHERE orders.state = 'paid')" }

    it "refuses a query with a RECURSIVE WITH" do
      expect(rewritten("WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT r.n FROM r WHERE r.n < 1)," \
                       "#{paid} SELECT paid.user_id FROM paid, r WHERE paid.user_id = r.n")).to eq([])
    end

    it "refuses a query with a data-modifying CTE" do
      sql = "WITH gone AS (DELETE FROM public.orders RETURNING orders.id), paid AS MATERIALIZED " \
            "(SELECT orders.user_id FROM public.orders) SELECT paid.user_id FROM paid, gone"
      expect(rule.rewrites(PgQuery.parse(sql), catalog)).to eq([])
    end

    # The deparser writes 't'::boolean as true, another tree, so the volatility
    # check can't read the body.
    it "refuses a body pg_query can't deparse faithfully" do
      sql = "WITH paid AS MATERIALIZED (SELECT orders.user_id FROM public.orders WHERE 't'::boolean) " \
            "SELECT paid.user_id FROM paid"
      expect(rule.rewrites(PgQuery.parse(sql), catalog)).to eq([])
    end

    it "refuses a body that calls a volatile function" do
      expect(rewritten("WITH picked AS MATERIALIZED (SELECT orders.user_id, random() AS r FROM public.orders) " \
                       "SELECT picked.r FROM picked WHERE picked.user_id = 1")).to eq([])
    end

    it "refuses a CTE whose name starts with quaack_, as shared_scan_cte names its own" do
      expect(rewritten("WITH quaack_scan_of_orders AS MATERIALIZED (SELECT * FROM public.orders " \
                       "WHERE orders.state = 'paid') SELECT a.id FROM quaack_scan_of_orders a " \
                       "JOIN quaack_scan_of_orders b ON b.user_id = a.user_id")).to eq([])
    end

    describe "a condition that could run on rows the body drops, and raise" do
      it "refuses a reader's condition that can raise on the CTE's columns" do
        sql = "#{matched} SELECT matched.id FROM matched WHERE matched.total / matched.qty > 3"
        expect(rewritten(sql)).to eq([])
        expect_raises_unfenced(sql)
      end

      it "refuses a reader's condition on a column that the body computes with an expression that can raise" do
        sql = "WITH matched AS MATERIALIZED (SELECT orders.id, orders.total / orders.qty AS ratio " \
              "FROM public.orders JOIN public.users ON users.id = orders.user_id) " \
              "SELECT matched.id FROM matched WHERE matched.ratio > 3"
        expect(rewritten(sql)).to eq([])
        expect_raises_unfenced(sql)
      end

      it "refuses a condition on a derived table's column that reads the CTE with an expression that can raise" do
        sql = "#{matched} SELECT s.id FROM (SELECT matched.id, matched.total / matched.qty AS ratio " \
              "FROM matched) s WHERE s.ratio > 3"
        expect(rewritten(sql)).to eq([])
        expect_raises_unfenced(sql)
      end

      it "refuses a condition in a subquery that reads the CTE" do
        expect(rewritten("#{matched} SELECT users.id FROM public.users WHERE EXISTS (SELECT 1 FROM matched " \
                         "WHERE matched.user_id = users.id AND matched.total / matched.qty > 3)")).to eq([])
      end

      it "refuses a join's ON condition that can raise on the CTE's columns" do
        expect(rewritten("#{matched} SELECT users.id FROM matched JOIN public.users " \
                         "ON users.id = matched.user_id AND matched.total / matched.qty > 3")).to eq([])
      end

      it "refuses a HAVING condition, outside an aggregate, that can raise on the CTE's columns" do
        sql = "#{matched} SELECT matched.total FROM matched GROUP BY matched.total, matched.qty " \
              "HAVING matched.total / matched.qty > 3"
        expect(rewritten(sql)).to eq([])
        expect_raises_unfenced(sql)
      end

      it "refuses a function in FROM whose arguments can raise on the CTE's columns" do
        expect(rewritten("#{matched} SELECT g.n FROM matched, " \
                         "LATERAL generate_series(1, matched.total / matched.qty) g(n)")).to eq([])
      end

      it "refuses a VALUES row that computes from the CTE's columns with an expression that can raise" do
        expect(rewritten("#{matched} SELECT v.r FROM matched, " \
                         "LATERAL (VALUES (matched.total / matched.qty)) v(r) WHERE v.r > 3")).to eq([])
      end

      it "refuses a body that computes a column with a call that can raise" do
        expect(rewritten("WITH paid AS MATERIALIZED (SELECT orders.user_id, lower(orders.state) AS state " \
                         "FROM public.orders) SELECT paid.user_id FROM paid WHERE paid.state = 'paid'")).to eq([])
      end
    end

    describe "a body that could give each read other rows" do
      it "refuses a CTE read twice whose body has a LIMIT" do
        expect(rewritten("WITH few AS (SELECT orders.id FROM public.orders ORDER BY orders.total LIMIT 3) " \
                         "SELECT a.id FROM few a JOIN few b ON b.id = a.id")).to eq([])
      end

      it "refuses a CTE read twice whose body groups" do
        expect(rewritten("WITH totals AS (SELECT orders.user_id, sum(orders.total) AS total FROM public.orders " \
                         "GROUP BY orders.user_id) SELECT a.total FROM totals a " \
                         "JOIN totals b ON b.user_id = a.user_id")).to eq([])
      end

      it "refuses a CTE read twice whose body groups with no aggregate" do
        expect(rewritten("WITH states AS (SELECT orders.state FROM public.orders GROUP BY orders.state) " \
                         "SELECT a.state FROM states a JOIN states b ON b.state = a.state")).to eq([])
      end

      it "refuses a CTE read twice whose body is a UNION" do
        expect(rewritten("WITH ids AS (SELECT orders.user_id AS id FROM public.orders " \
                         "UNION SELECT users.id FROM public.users) " \
                         "SELECT a.id FROM ids a JOIN ids b ON b.id = a.id")).to eq([])
      end

      it "refuses a CTE read twice whose body is an INTERSECT ALL, which keeps one of two equal values by order" do
        expect(rewritten("WITH ids AS (SELECT orders.user_id AS id FROM public.orders " \
                         "INTERSECT ALL SELECT users.id FROM public.users) " \
                         "SELECT a.id FROM ids a JOIN ids b ON b.id = a.id")).to eq([])
      end

      it "refuses a CTE read twice whose body is an EXCEPT ALL, which keeps one of two equal values by order" do
        expect(rewritten("WITH ids AS (SELECT orders.user_id AS id FROM public.orders " \
                         "EXCEPT ALL SELECT users.id FROM public.users) " \
                         "SELECT a.id FROM ids a JOIN ids b ON b.id = a.id")).to eq([])
      end

      it "refuses a CTE read twice whose body has an OFFSET and no LIMIT" do
        expect(rewritten("WITH rest AS (SELECT orders.id FROM public.orders ORDER BY orders.total OFFSET 3) " \
                         "SELECT a.id FROM rest a JOIN rest b ON b.id = a.id")).to eq([])
      end

      it "refuses a CTE read twice whose body holds a subquery with a LIMIT" do
        expect(rewritten("WITH few AS (SELECT users.id FROM public.users WHERE users.id IN " \
                         "(SELECT orders.user_id FROM public.orders ORDER BY orders.total LIMIT 3)) " \
                         "SELECT a.id FROM few a JOIN few b ON b.id = a.id")).to eq([])
      end

      it "rewrites a CTE read twice whose body is a UNION ALL" do
        expect_rewrites(
          "WITH ids AS (SELECT orders.user_id AS id FROM public.orders UNION ALL SELECT users.id FROM public.users) " \
          "SELECT a.id FROM ids a JOIN ids b ON b.id = a.id",
          "WITH ids AS NOT MATERIALIZED (SELECT orders.user_id AS id FROM public.orders " \
          "UNION ALL SELECT users.id FROM public.users) SELECT a.id FROM ids a JOIN ids b ON b.id = a.id"
        )
      end

      it "refuses a CTE read twice whose body has a DISTINCT" do
        expect(rewritten("WITH states AS (SELECT DISTINCT orders.state FROM public.orders) " \
                         "SELECT a.state FROM states a JOIN states b ON b.state = a.state")).to eq([])
      end

      it "refuses a CTE read twice whose body calls a window function" do
        expect(rewritten("WITH ranked AS (SELECT orders.id, row_number() OVER () AS n FROM public.orders) " \
                         "SELECT a.id FROM ranked a JOIN ranked b ON b.n = a.n")).to eq([])
      end

      it "refuses a CTE read once, from a subquery, whose body has a LIMIT" do
        expect(rewritten("WITH top AS MATERIALIZED (SELECT orders.user_id FROM public.orders " \
                         "ORDER BY orders.total DESC LIMIT 2) SELECT users.id FROM public.users " \
                         "WHERE users.id IN (SELECT top.user_id FROM top)")).to eq([])
      end

      it "refuses a CTE read once, from a LATERAL subquery, whose body groups" do
        expect(rewritten("WITH totals AS MATERIALIZED (SELECT orders.user_id, sum(orders.total) AS total " \
                         "FROM public.orders GROUP BY orders.user_id) SELECT users.id, t.total FROM public.users, " \
                         "LATERAL (SELECT totals.total FROM totals WHERE totals.user_id = users.id) t")).to eq([])
      end

      it "refuses a CTE read once, from a CTE that's read twice, whose body groups" do
        expect(rewritten("WITH totals AS MATERIALIZED (SELECT orders.user_id, sum(orders.total) AS total " \
                         "FROM public.orders GROUP BY orders.user_id), " \
                         "mine AS (SELECT totals.user_id, totals.total FROM totals) " \
                         "SELECT a.total FROM mine a JOIN mine b ON b.user_id = a.user_id")).to eq([])
      end

      # few runs once, inside mine's one stored copy. Unstored, mine would
      # run it once per read.
      it "refuses a CTE read twice whose body reads a CTE with a LIMIT" do
        expect(rewritten("WITH few AS NOT MATERIALIZED (SELECT orders.id FROM public.orders ORDER BY orders.id " \
                         "LIMIT 3), mine AS (SELECT few.id FROM few) " \
                         "SELECT a.id FROM mine a JOIN mine b ON b.id = a.id")).to eq([])
      end
    end
  end
end
