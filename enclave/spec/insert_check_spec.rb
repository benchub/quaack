# frozen_string_literal: true

require "quaack/enclave/insert_check"
require "quaack/enclave/error_filter"

# Every example runs against real Postgres, since the check reads the
# catalog for columns and function volatility, and an accepted insert
# should be one Postgres runs. Each one gets a fresh copy of the sample
# schema (public.customers and public.orders), plus a sales schema with a
# table outside the subset and a few functions.
RSpec.describe Quaack::Enclave::InsertCheck do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  # The schema-dump subset's tables.
  let(:tables) { [table_name("public", "orders"), table_name("public", "customers"), table_name("sales", "items")] }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.items (id int, order_id bigint, qty int, sku text, tags text[], shipped date);
      CREATE TABLE sales.refunds (id int);
      CREATE FUNCTION public.steady(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$SELECT $1$$;
      CREATE FUNCTION sales.steady(text) RETURNS text LANGUAGE sql STABLE AS $$SELECT $1$$;
      CREATE FUNCTION public.bump(text) RETURNS text LANGUAGE sql VOLATILE AS $$SELECT $1$$;
    SQL
  end

  def check(sql, settings = nil, tables: self.tables) = described_class.check(sql, tables, settings, conn)

  # The Error for rule, with message if given, and no cause. The block, if
  # any, gets the error too.
  def rejected(rule, message = nil, &also)
    raise_error(described_class::Error) do |error|
      expect([error.rule, error.cause]).to eq([rule, nil])
      expect(error.message).to eq(message || error.message).and start_with("#{rule}: ")
      also&.call(error)
    end
  end

  # The accepted insert, checked to be one Postgres runs.
  def runs(sql, settings = nil)
    accepted = check(sql, settings)
    conn.exec(accepted.sql)
    accepted
  end

  describe "an acceptable insert" do
    it "comes back deparsed, with its parse and table" do
      accepted = runs("INSERT INTO public.customers (name, email, created_at) " \
                      "VALUES ('Ann', 'a@example.com', '2024-01-01 00:00:00+00') /* note */")

      expect(accepted).to be_a(described_class::Accepted)
      expect(accepted.sql).to eq("INSERT INTO public.customers (name, email, created_at) " \
                                 "VALUES ('Ann', 'a@example.com', '2024-01-01 00:00:00+00')")
      expect(accepted.parse.deparse).to eq(accepted.sql)
      expect(accepted.table).to eq(table_name("public", "customers"))
    end

    # What an LLM writes to fill a fixture.
    {
      "several rows" => "INSERT INTO sales.items (id, order_id, qty, sku) VALUES (1, 10, 2, 'a'), (2, 10, 1, 'b')",
      "NULL and DEFAULT" => "INSERT INTO sales.items (id, order_id, qty, sku) VALUES (1, NULL, DEFAULT, NULL)",
      "negative and decimal numbers" => "INSERT INTO sales.items (id, qty) VALUES (-1, CAST(-2.5 AS int)), (-3, -4)",
      "typed literals and casts" => "INSERT INTO sales.items (id, shipped, qty) VALUES (1, '2024-01-01'::date, " \
                                    "CAST('3' AS integer)), (2, date '2024-02-01', '4'::int4)",
      "an array" => "INSERT INTO sales.items (id, tags) VALUES (1, ARRAY['x', 'y']), (2, '{z}'), (3, ARRAY[]::text[])",
      "immutable calls" => "INSERT INTO sales.items (id, sku) VALUES (1, lower('A')), (2, public.steady(upper('b')))",
      "an identity DEFAULT" => "INSERT INTO public.orders (id, customer_id, status, total_cents, created_at) " \
                               "VALUES (DEFAULT, 1, 'open', 100, '2024-01-01T00:00:00Z'::timestamptz)",
      # Task 20260927-24: a counterexample may set a GENERATED ALWAYS key.
      "OVERRIDING SYSTEM VALUE" => "INSERT INTO public.customers (id, name, email, created_at) " \
                                   "OVERRIDING SYSTEM VALUE VALUES (900001, 'n', 'o@x', '2024-01-01'::date)",
      "OVERRIDING USER VALUE" => "INSERT INTO public.customers (id, name, email, created_at) " \
                                 "OVERRIDING USER VALUE VALUES (900001, 'n', 'o@x', '2024-01-01'::date)"
    }.each do |what, sql|
      it "accepts #{what}" do
        conn.exec("INSERT INTO public.customers (name, email, created_at) VALUES ('c', 'c@x', now())")
        expect(runs(sql).sql).to eq(PgQuery.parse(sql).deparse)
      end
    end

    it "accepts a table named with quotes, and names it unquoted" do
      conn.exec('CREATE TABLE sales."Line Items" ("Qty" int)')
      accepted = check('INSERT INTO sales."Line Items" ("Qty") VALUES (1)',
                       tables: [table_name("sales", "Line Items")])
      expect(accepted.table).to eq(table_name("sales", "Line Items"))
    end
  end

  describe "an insert that doesn't parse" do
    it "is refused as unparsable, without quoting pg_query's message" do
      expect { check("INSERT INTO sales.items (id) VALUES (1") }
        .to rejected("unparsable", "unparsable: the insert doesn't parse #{PARSER_NOTE}")
    end
  end

  describe "a statement that isn't exactly one INSERT" do
    it "refuses two statements, even two INSERTs" do
      expect { check("INSERT INTO sales.items (id) VALUES (1); INSERT INTO sales.items (id) VALUES (2)") }
        .to rejected("not_insert", "not_insert: 2 statements, not one")
    end

    it "refuses an empty statement" do
      expect { check("") }.to rejected("not_insert", "not_insert: 0 statements, not one")
    end

    {
      "SELECT" => ["SELECT 1", "SelectStmt"],
      "UPDATE" => ["UPDATE sales.items SET qty = 1", "UpdateStmt"],
      "SELECT set_config" => ["SELECT set_config('a.b', 'c', false)", "SelectStmt"],
      "COPY" => ["COPY sales.items FROM STDIN", "CopyStmt"]
    }.each do |what, (sql, type)|
      it "refuses a #{what}" do
        expect { check(sql) }.to rejected("not_insert", "not_insert: #{type}, not InsertStmt")
      end
    end
  end

  describe "refused forms" do
    {
      "with" => ["WITH x AS (SELECT 1) INSERT INTO sales.items (id) VALUES (1)", "WITH"],
      "on_conflict" => ["INSERT INTO sales.items (id) VALUES (1) ON CONFLICT DO NOTHING", "ON CONFLICT"],
      "returning" => ["INSERT INTO sales.items (id) VALUES (1) RETURNING id", "RETURNING"]
    }.each do |rule, (sql, name)|
      it "refuses #{rule}" do
        expect { check(sql) }.to rejected(rule, "#{rule}: #{name} isn't allowed")
      end
    end

    it "refuses INSERT ... SELECT" do
      expect { check("INSERT INTO sales.items (id) SELECT id FROM sales.refunds") }
        .to rejected("insert_select", "insert_select: the rows must be a VALUES list")
    end

    it "refuses a VALUES list with ORDER BY or LIMIT" do
      expect { check("INSERT INTO sales.items (id) VALUES (1), (2) LIMIT 1") }.to rejected("insert_select")
    end

    it "refuses DEFAULT VALUES" do
      expect { check("INSERT INTO sales.items DEFAULT VALUES") }
        .to rejected("missing_columns", "missing_columns: the insert must list its columns")
    end

    it "refuses a missing column list" do
      expect { check("INSERT INTO sales.items VALUES (1)") }.to rejected("missing_columns")
    end

    it "refuses an alias" do
      expect { check("INSERT INTO sales.items AS i (id) VALUES (1)") }
        .to rejected("alias", "alias: an alias isn't allowed")
    end
  end

  describe "the table" do
    it "refuses an unqualified name" do
      expect { check("INSERT INTO orders (status) VALUES ('x')") }
        .to rejected("unqualified_table", "unqualified_table: orders isn't schema qualified")
    end

    it "refuses a table outside the subset, naming it" do
      expect { check("INSERT INTO sales.refunds (id) VALUES (1)") }
        .to rejected("unknown_relation", "unknown_relation: sales.refunds isn't a table in the subset schema")
    end

    it "compares the schema too" do
      expect { check("INSERT INTO sales.orders (id) VALUES (1)") }.to rejected("unknown_relation")
    end

    it "refuses a name with a database in front" do
      expect { check("INSERT INTO db.sales.items (id) VALUES (1)") }
        .to rejected("unknown_relation", "unknown_relation: sales.items is named with a database")
    end
  end

  describe "the columns" do
    it "refuses a column the table doesn't have, naming it" do
      expect { check("INSERT INTO sales.items (id, colour) VALUES (1, 'red')") }
        .to rejected("unknown_column", "unknown_column: sales.items has no column colour")
    end

    it "refuses a dropped column" do
      conn.exec("ALTER TABLE sales.items DROP COLUMN sku")
      expect { check("INSERT INTO sales.items (id, sku) VALUES (1, 'a')") }.to rejected("unknown_column")
    end

    it "refuses a system column" do
      expect { check("INSERT INTO sales.items (ctid) VALUES ('(0,1)')") }.to rejected("unknown_column")
    end

    it "refuses a subscripted or field column" do
      expect { check("INSERT INTO sales.items (tags[1]) VALUES ('a')") }
        .to rejected("unknown_column", "unknown_column: tags is subscripted or has a field")
    end

    it "refuses a table the catalog doesn't have" do
      expect { check("INSERT INTO sales.gone (id) VALUES (1)", tables: [table_name("sales", "gone")]) }
        .to rejected("unknown_column", "unknown_column: sales.gone has no column id")
    end
  end

  describe "the values" do
    {
      "a subquery" => ["(SELECT 1)", "SubLink"],
      "a subquery in an array" => ["ARRAY[(SELECT 1)]", "SubLink"],
      "a column in an array" => ["cardinality(ARRAY[id])", "ColumnRef"],
      "an EXISTS" => ["EXISTS (SELECT 1)::int", "SubLink"],
      "a column reference" => %w[id ColumnRef],
      "a placeholder" => ["$1", "ParamRef"],
      "an operator" => ["1 + 1", "A_Expr"],
      "a CASE" => ["CASE WHEN true THEN 1 END", "CaseExpr"],
      "a row" => ["ROW(1)", "RowExpr"],
      "a named argument" => ["public.steady(x => 'a')::int", "NamedArgExpr"],
      "a DEFAULT inside a call" => ["lower(DEFAULT)::int", "SetToDefault"],
      "an aggregate's FILTER" => ["max(1) FILTER (WHERE true)", "an aggregate or window call"],
      "a window call" => ["row_number() OVER ()", "an aggregate or window call"]
    }.each do |what, (value, detail)|
      it "refuses #{what}" do
        expect { check("INSERT INTO sales.items (id) VALUES (#{value})") }
          .to rejected("not_plain_value", "not_plain_value: a value uses #{detail}")
      end
    end

    it "checks every row, not just the first" do
      expect { check("INSERT INTO sales.items (id) VALUES (1), ((SELECT 2))") }.to rejected("not_plain_value")
    end
  end

  describe "functions" do
    {
      "now()" => ["now()::text", "function pg_catalog.now is stable, not immutable"],
      "random()" => ["random()::text", "function pg_catalog.random is volatile, not immutable"],
      "nextval" => ["nextval('s')::text", "function pg_catalog.nextval is volatile, not immutable"],
      "set_config" => ["set_config('a.b', 'c', false)", "function pg_catalog.set_config is volatile, not immutable"],
      "pg_advisory_lock" => ["pg_advisory_lock(1)::text",
                             "function pg_catalog.pg_advisory_lock is volatile, not immutable"],
      "a variadic call with more arguments than its declared ones" =>
        ["concat('a', 'b', 'c')", "function pg_catalog.concat is stable, not immutable"],
      "a volatile function of our own" => ["public.bump('a')", "function public.bump is volatile, not immutable"],
      "one nested in an immutable call" => ["lower(now()::text)",
                                            "function pg_catalog.now is stable, not immutable"]
    }.each do |what, (value, detail)|
      it "refuses #{what}" do
        expect { check("INSERT INTO sales.items (sku) VALUES (#{value})") }
          .to rejected("not_immutable", "not_immutable: #{detail}")
      end
    end

    it "looks up an unqualified function in the plan's search path" do
      expect { check("INSERT INTO sales.items (sku) VALUES (steady('a'))", { "search_path" => "sales, public" }) }
        .to rejected("not_immutable", "not_immutable: function sales.steady is stable, not immutable")
      expect(check("INSERT INTO sales.items (sku) VALUES (steady('a'))").table).to eq(table_name("sales", "items"))
    end

    it "refuses a bad search path" do
      expect { check("INSERT INTO sales.items (sku) VALUES (lower('a'))", { "search_path" => "public," }) }
        .to rejected("bad_search_path", "bad_search_path: search_path public, has an empty entry")
    end

    it "refuses a cast whose function is volatile, through the volatility check" do
      conn.exec(<<~SQL)
        CREATE TYPE sales.odd;
        CREATE FUNCTION sales.odd_in(cstring) RETURNS sales.odd LANGUAGE internal VOLATILE AS 'textin';
        CREATE FUNCTION sales.odd_out(sales.odd) RETURNS cstring LANGUAGE internal IMMUTABLE AS 'textout';
        CREATE TYPE sales.odd (INPUT = sales.odd_in, OUTPUT = sales.odd_out, LIKE = text);
      SQL
      expect { check("INSERT INTO sales.items (sku) VALUES ('a'::sales.odd::text)") }
        .to rejected("volatile_function", "volatile_function: cast to sales.odd calls volatile function sales.odd_in")
    end
  end

  describe "an insert pg_query deparses wrong" do
    # The deparser writes 't'::boolean as true, which parses to another
    # tree.
    it "is refused as deparse_mismatch" do
      expect { check("INSERT INTO sales.items (sku) VALUES ('t'::boolean::text)") }.to rejected("deparse_mismatch")
    end
  end

  describe "the order of the checks" do
    it "checks the statement, then its forms, then the table, the columns, the values, and the functions" do
      bad = "INSERT INTO sales.items (id, colour) VALUES (random()::int, (SELECT 1))"
      expect { check("#{bad}; SELECT 1") }.to rejected("not_insert")
      expect { check("WITH x AS (SELECT 1) #{bad} RETURNING id") }.to rejected("with")
      expect { check(bad.sub("sales.items", "items")) }.to rejected("unqualified_table")
      expect { check(bad.sub("sales.items", "sales.refunds")) }.to rejected("unknown_relation")
      expect { check(bad) }.to rejected("unknown_column")
      expect { check(bad.sub("colour", "qty")) }.to rejected("not_plain_value")
      expect { check(bad.sub("colour", "qty").sub("(SELECT 1)", "1")) }.to rejected("not_immutable")
    end
  end

  # The inserts are untrusted and hold literals. Every rejection's message,
  # and the error line ErrorFilter makes of it, names only the rule and
  # shape-class names, so no literal comes out.
  describe "a sentinel in the insert" do
    sentinel = "SENTINEL-4c92aa"

    def self.planted(sentinel, table: "sales.items", column: "sku", value: "'#{sentinel}'", tail: "")
      "/* #{sentinel} */ INSERT INTO #{table} (id, #{column}) VALUES (1, #{value}), (2, '#{sentinel}')#{tail} " \
        "-- #{sentinel}\n"
    end

    def refusal(sql, rule, settings = nil)
      error = nil
      expect { check(sql, settings) }.to(rejected(rule) { |raised| error = raised })
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "10")
      expect(line).to include(%("rule":"#{rule}"))
      [error.message, line]
    end

    {
      "unparsable" => planted(sentinel, tail: " ("),
      "not_insert" => "#{planted(sentinel)}; SELECT '#{sentinel}'",
      "on_conflict" => planted(sentinel, tail: " ON CONFLICT DO NOTHING"),
      "returning" => planted(sentinel, tail: " RETURNING '#{sentinel}'"),
      "unqualified_table" => planted(sentinel, table: "items"),
      "unknown_relation" => planted(sentinel, table: "sales.refunds"),
      "unknown_column" => planted(sentinel, column: "colour"),
      "not_plain_value" => planted(sentinel, value: "(SELECT '#{sentinel}')"),
      "not_immutable" => planted(sentinel, value: "concat(now()::text, '#{sentinel}')"),
      "deparse_mismatch" => planted(sentinel, value: "'t'::boolean::text")
    }.each do |rule, sql|
      it "never shows up when it's refused as #{rule}" do
        expect(sql.scan(sentinel).size).to be >= 3
        refusal(sql, rule).each { |text| expect(text).not_to include(sentinel) }
      end
    end

    it "is accepted, literals and all, when nothing is wrong" do
      expect(check(self.class.planted(sentinel)).sql)
        .to eq("INSERT INTO sales.items (id, sku) VALUES (1, '#{sentinel}'), (2, '#{sentinel}')")
    end

    # Column names are shape, so a message may name them. This proves the
    # message assertions above would catch a sentinel that got in.
    it "is caught when it's in a name the message is allowed to name" do
      message, line = refusal(self.class.planted(sentinel, column: %("#{sentinel}")), "unknown_column")
      expect(message).to include(sentinel)
      expect(line).not_to include(sentinel)
    end
  end
end
