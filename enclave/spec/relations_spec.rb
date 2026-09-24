# frozen_string_literal: true

require "quaack/enclave/relations"
require "quaack/enclave/error_filter"

# Every example runs against real Postgres, since checking a relkind means
# reading the production catalog. Each one gets a fresh copy of the sample
# schema (public.customers and public.orders), plus a sales schema with a
# second table, and a relation of every other kind.
RSpec.describe Quaack::Enclave::Relations do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.items (id int, order_id bigint, qty int);
      CREATE VIEW public.order_view AS SELECT id, status FROM public.orders;
      CREATE MATERIALIZED VIEW public.order_mv AS SELECT id, status FROM public.orders;
      CREATE TABLE public.parted (id int) PARTITION BY RANGE (id);
      CREATE TABLE public.parted_low PARTITION OF public.parted FOR VALUES FROM (0) TO (100);
      CREATE INDEX parted_id_idx ON public.parted (id);
      CREATE EXTENSION postgres_fdw;
      CREATE SERVER elsewhere FOREIGN DATA WRAPPER postgres_fdw;
      CREATE FOREIGN TABLE public.remote_orders (id bigint) SERVER elsewhere;
      CREATE SEQUENCE public.counter;
      CREATE TYPE public.pair AS (a int, b int);
    SQL
  end

  def check(sql, settings = nil) = described_class.check(sql, settings, conn)

  # The Error for rule, with message if given, and no cause. The block, if
  # any, gets the error too.
  def rejected(rule, message = nil, &also)
    raise_error(described_class::Error) do |error|
      expect([error.rule, error.cause]).to eq([rule, nil])
      expect(error.message).to eq(message || error.message).and start_with("#{rule}: ")
      also&.call(error)
    end
  end

  # The toast table behind public.orders, as schema and name.
  def toast_table
    conn.exec(<<~SQL).values.first
      SELECT n.nspname, t.relname
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_class t ON t.oid = c.reltoastrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
      WHERE c.oid = 'public.orders'::regclass
    SQL
  end

  describe "a query that uses only plain tables" do
    it "comes back qualified, with its parse and its relations in the order it names them" do
      sql = <<~SQL
        SELECT o.id FROM orders o JOIN customers c ON c.id = o.customer_id
        WHERE o.id IN (SELECT order_id FROM sales.items) AND EXISTS (SELECT 1 FROM orders)
      SQL

      result = check(sql)

      expect(result).to be_a(described_class::Result)
      expect(result.sql).to eq(
        "SELECT o.id FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
        "WHERE o.id IN (SELECT order_id FROM sales.items) AND EXISTS (SELECT 1 FROM public.orders)"
      )
      expect(result.parse.deparse).to eq(result.sql)
      expect(result.relations)
        .to eq([table_name("public", "orders"), table_name("public", "customers"), table_name("sales", "items")])
    end

    it "accepts a partition, which is a plain table of its own" do
      expect(check("SELECT id FROM public.parted_low").relations).to eq([table_name("public", "parted_low")])
    end
  end

  # Every place the supported SQL list lets a relation go. %s is where the
  # relation goes.
  positions = {
    "FROM" => "SELECT 1 FROM %s",
    "a join" => "SELECT 1 FROM public.orders o JOIN %s x ON true",
    "a subquery in FROM" => "SELECT 1 FROM (SELECT 1 FROM %s) s",
    "a CTE's body" => "WITH c AS (SELECT 1 FROM %s) SELECT 1 FROM c",
    "a later CTE's body" => "WITH a AS (SELECT 1), b AS (SELECT 1 FROM a, %s) SELECT 1 FROM b",
    "a recursive CTE's body" =>
      "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r, %s WHERE n < 3) SELECT n FROM r",
    "a LATERAL subquery" => "SELECT 1 FROM public.orders o, LATERAL (SELECT 1 FROM %s) l",
    "an IN sublink" => "SELECT 1 FROM public.orders WHERE id IN (SELECT 1 FROM %s)",
    "an EXISTS sublink" => "SELECT 1 FROM public.orders WHERE EXISTS (SELECT 1 FROM %s)",
    "an ANY sublink" => "SELECT 1 FROM public.orders WHERE id = ANY (SELECT 1 FROM %s)",
    "a scalar sublink in the select list" => "SELECT (SELECT 1 FROM %s LIMIT 1)",
    "a sublink in HAVING" => "SELECT count(*) FROM public.orders HAVING count(*) > (SELECT count(*) FROM %s)",
    "a sublink in a join's ON" => "SELECT 1 FROM public.orders o JOIN public.customers c ON EXISTS (SELECT 1 FROM %s)",
    "a set operation's second branch" => "SELECT 1 FROM public.orders UNION SELECT 1 FROM %s",
    "a CTE inside a subquery" => "SELECT 1 FROM (WITH c AS (SELECT 1 FROM %s) SELECT 1 FROM c) s"
  }

  describe "the relations it finds" do
    positions.each do |where, template|
      it "include a table in #{where}" do
        expect(check(format(template, "sales.items")).relations).to include(table_name("sales", "items"))
      end

      it "include a view in #{where}, and refuse it" do
        expect { check(format(template, "public.order_view")) }
          .to rejected("view_relation", "view_relation: public.order_view is a view (relkind v), not a plain table")
      end
    end

    it "leave out a reference to a CTE, even one named for a view" do
      result = check("WITH order_view AS (SELECT id FROM orders) SELECT id FROM order_view")
      expect(result.relations).to eq([table_name("public", "orders")])
    end

    it "include a schema-qualified name, even one that matches a CTE's" do
      expect { check("WITH order_view AS (SELECT id FROM orders) SELECT id FROM public.order_view") }
        .to rejected("view_relation")
    end

    it "list each relation once" do
      relations = check("SELECT 1 FROM orders a, public.orders b, orders c").relations
      expect(relations).to eq([table_name("public", "orders")])
    end
  end

  describe "a relation that isn't a plain table" do
    {
      "public.order_view" => ["view_relation", "a view (relkind v)"],
      "public.order_mv" => ["matview_relation", "a materialized view (relkind m)"],
      "public.parted" => ["partitioned_relation", "a partitioned table (relkind p)"],
      "public.remote_orders" => ["foreign_relation", "a foreign table (relkind f)"],
      "public.counter" => ["sequence_relation", "a sequence (relkind S)"],
      "public.customers_id_seq" => ["sequence_relation", "a sequence (relkind S)"],
      "public.pair" => ["composite_type_relation", "a composite type (relkind c)"],
      "public.orders_customer_id_idx" => ["index_relation", "an index (relkind i)"],
      "public.parted_id_idx" => ["index_relation", "a partitioned index (relkind I)"]
    }.each do |name, (rule, kind)|
      it "is refused as #{rule} when it's #{kind}, naming it" do
        expect { check("SELECT * FROM #{name}") }.to rejected(rule, "#{rule}: #{name} is #{kind}, not a plain table")
      end
    end

    it "is refused as toast_relation when it's a toast table" do
      schema, name = toast_table
      expect { check("SELECT chunk_id FROM #{schema}.#{name}") }
        .to rejected("toast_relation",
                     "toast_relation: #{schema}.#{name} is a toast table (relkind t), not a plain table")
    end

    it "is refused after plain tables that come before it" do
      expect { check("SELECT 1 FROM orders, customers, sales.items, public.order_mv") }
        .to rejected("matview_relation")
    end

    it "is the first one named, when there are several" do
      expect { check("SELECT 1 FROM orders, public.parted, public.order_view") }.to rejected("partitioned_relation")
      expect { check("SELECT 1 FROM orders, public.order_view, public.parted") }.to rejected("view_relation")
    end

    it "is refused with not_a_table when its relkind has no rule of its own" do
      expect(described_class.rule_for("x")).to eq("not_a_table")
    end
  end

  describe "resolving names" do
    it "resolves an unqualified name with the plan's search path, as RelationQualifier does" do
      conn.exec("CREATE VIEW sales.orders AS SELECT id FROM public.orders")

      expect { check("SELECT id FROM orders", { "search_path" => "sales, public" }) }
        .to rejected("view_relation", "view_relation: sales.orders is a view (relkind v), not a plain table")
      expect(check("SELECT id FROM orders").relations).to eq([table_name("public", "orders")])
    end

    it "reads the relkind of the relation in its own schema, not another of the same name" do
      conn.exec("CREATE VIEW sales.orders AS SELECT id FROM public.orders")

      expect(check("SELECT id FROM public.orders").relations).to eq([table_name("public", "orders")])
      expect { check("SELECT id FROM sales.orders") }.to rejected("view_relation")
    end

    it "refuses a name no schema in the search path has" do
      expect { check("SELECT id FROM nowhere") }
        .to rejected("unknown_relation", "unknown_relation: relation nowhere isn't schema qualified, and no schema " \
                                         "in the search path (pg_catalog, postgres, public) has it")
    end

    it "refuses a qualified name that doesn't exist" do
      expect { check("SELECT id FROM public.nowhere") }
        .to rejected("unknown_relation", "unknown_relation: public.nowhere doesn't exist")
    end

    it "refuses a search path that doesn't read" do
      expect { check("SELECT id FROM orders", { "search_path" => "public," }) }
        .to rejected("bad_search_path", "bad_search_path: search_path public, has an empty entry")
    end
  end

  describe "a query it can't check" do
    it "is refused as parse_error, without quoting pg_query's message" do
      expect { check("SELECT 'x' FROM") }.to rejected("parse_error", "parse_error: the query doesn't parse")
    end

    it "is refused as unsupported_construct when it uses something outside SupportedSql" do
      expect { check("SELECT id FROM orders FOR UPDATE") }
        .to rejected("unsupported_construct", "unsupported_construct: LockingClause")
    end

    it "is refused as deparse_mismatch when pg_query would deparse it wrong" do
      expect { check("SELECT id FROM orders WHERE (status = 'a') IS NOT DISTINCT FROM (true AND false)") }
        .to rejected("deparse_mismatch")
    end
  end

  # Relation names are shape, so a message may name them, but nothing else
  # in the query comes out: not in a refusal's message, not in the error
  # line ErrorFilter makes of it, and not in the relations it lists.
  describe "a sentinel in the query" do
    sentinel = "SENTINEL-3a7f20"

    # A query with the sentinel in a comment, a string literal, a quoted
    # column alias, a cast's literal, a quoted table alias, a line comment,
    # and a comparison, plus whatever gets it refused.
    def self.planted(sentinel, from: "orders", tail: "")
      "/* #{sentinel} */ SELECT '#{sentinel}' AS \"#{sentinel}\", '#{sentinel}'::text " \
        "FROM #{from} AS \"#{sentinel}a\" -- #{sentinel}\nWHERE 'x' <> '#{sentinel}'#{tail}"
    end

    # The refusal's message and error line, once the refusal is checked to
    # be for rule.
    def refusal(sql, rule, settings = nil)
      error = nil
      expect { check(sql, settings) }.to(rejected(rule) { |raised| error = raised })
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "3a")
      expect(line).to include(%("rule":"#{rule}"))
      [error.message, line]
    end

    {
      "parse_error" => [planted(sentinel, tail: " FROM")],
      "unsupported_construct" => [planted(sentinel, tail: " FOR UPDATE")],
      "bad_search_path" => [planted(sentinel), { "search_path" => "public," }],
      "unknown_relation" => [planted(sentinel, from: "public.nowhere")],
      "deparse_mismatch" => [planted(sentinel, tail: " AND ('x' = 'y') IS NOT DISTINCT FROM (true AND false)")],
      "view_relation" => [planted(sentinel, from: "order_view")],
      "foreign_relation" => [planted(sentinel, from: "remote_orders")]
    }.each do |rule, (sql, settings)|
      it "never shows up when it's refused as #{rule}" do
        expect(sql.scan(sentinel).size).to eq(7)
        refusal(sql, rule, settings).each { |text| expect(text).not_to include(sentinel) }
      end
    end

    it "stays out of the relations it lists, though the query keeps it" do
      result = check(self.class.planted(sentinel))
      expect(result.sql).to include(sentinel)
      expect(result.relations.map(&:to_s)).to all(satisfy { |name| !name.include?(sentinel) })
      expect(result.relations).to eq([table_name("public", "orders")])
    end

    # This proves the message assertions above would catch a sentinel that
    # got in. The error line never carries a message, so it stays clean
    # even then.
    it "is caught when it's in a name the message is allowed to name" do
      conn.exec(%(CREATE VIEW sales."#{sentinel}" AS SELECT 1 AS id))
      message, line = refusal(%(SELECT id FROM sales."#{sentinel}"), "view_relation")
      expect(message).to include(sentinel)
      expect(line).not_to include(sentinel)
    end
  end
end
