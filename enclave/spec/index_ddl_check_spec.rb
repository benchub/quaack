# frozen_string_literal: true

require "quaack/enclave/index_ddl_check"
require "quaack/enclave/error_filter"

# Every example runs against real Postgres, since the volatility check
# reads the production catalog, and an accepted statement should be one
# Postgres builds. Each one gets a fresh copy of the sample schema
# (public.customers and public.orders), plus a sales schema with a second
# table and a few functions.
RSpec.describe Quaack::Enclave::IndexDdlCheck do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  # The tables the query uses.
  let(:tables) { [table_name("public", "orders"), table_name("public", "customers"), table_name("sales", "items")] }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.items (id int, order_id bigint, qty int, sku text);
      CREATE TABLE sales.refunds (id int);
      CREATE FUNCTION public.bump(text) RETURNS text LANGUAGE sql VOLATILE AS $$SELECT $1$$;
      CREATE FUNCTION sales.bump(text) RETURNS text LANGUAGE sql VOLATILE AS $$SELECT $1$$;
      CREATE FUNCTION public.steady(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$SELECT $1$$;
      CREATE FUNCTION public.jumpy(int, int) RETURNS boolean LANGUAGE sql VOLATILE AS $$SELECT $1 = $2$$;
      CREATE OPERATOR public.=== (FUNCTION = public.jumpy, LEFTARG = int, RIGHTARG = int);
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

  # The accepted statement, checked to be one Postgres builds.
  def builds(sql, settings = nil)
    accepted = check(sql, settings)
    conn.exec(accepted.sql)
    accepted
  end

  describe "an acceptable statement" do
    it "comes back without its name, deparsed, with its parse and table" do
      accepted = builds("CREATE INDEX orders_status_created_idx ON public.orders (status, created_at DESC NULLS LAST)")

      expect(accepted).to be_a(described_class::Accepted)
      expect(accepted.sql).to eq("CREATE INDEX ON public.orders USING btree (status, created_at DESC NULLS LAST)")
      expect(accepted.parse.deparse).to eq(accepted.sql)
      expect(accepted.parse.tree.stmts.first.stmt.index_stmt.idxname).to eq("")
      expect(accepted.table).to eq(table_name("public", "orders"))
    end

    # What an LLM proposes for the queries apps and ORMs send.
    {
      "INCLUDE columns" => [
        "CREATE INDEX ON public.orders (customer_id) INCLUDE (total_cents, status)",
        "CREATE INDEX ON public.orders USING btree (customer_id) INCLUDE (total_cents, status)"
      ],
      "a partial index" => [
        "CREATE INDEX orders_open_idx ON public.orders (created_at) WHERE status = 'open'",
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'open'"
      ],
      "a partial index with a range and IS NULL" => [
        "CREATE INDEX ON public.orders (customer_id) WHERE total_cents > 1000 AND status IS NOT NULL",
        "CREATE INDEX ON public.orders USING btree (customer_id) WHERE total_cents > 1000 AND status IS NOT NULL"
      ],
      "an expression key" => [
        "CREATE INDEX customers_lower_email_idx ON public.customers (lower(email))",
        "CREATE INDEX ON public.customers USING btree (lower(email))"
      ],
      "an operator class" => [
        "CREATE INDEX ON public.customers (email text_pattern_ops)",
        "CREATE INDEX ON public.customers USING btree (email text_pattern_ops)"
      ],
      "a collation, and a direction" => [
        "CREATE INDEX ON public.orders (status COLLATE \"C\" DESC)",
        "CREATE INDEX ON public.orders USING btree (status COLLATE \"C\" DESC)"
      ],
      "a hash index" => [
        "CREATE INDEX ON public.orders USING hash (status)", "CREATE INDEX ON public.orders USING hash (status)"
      ],
      "a BRIN index" => [
        "CREATE INDEX ON public.orders USING brin (created_at)", "CREATE INDEX ON public.orders USING brin (created_at)"
      ],
      "an immutable user function" => [
        "CREATE INDEX ON sales.items (public.steady(sku))",
        "CREATE INDEX ON sales.items USING btree (public.steady(sku))"
      ],
      "an expression over two columns" => [
        "CREATE INDEX ON sales.items ((qty * 2), (sku || 'x'))",
        "CREATE INDEX ON sales.items USING btree ((qty * 2), (sku || 'x'))"
      ]
    }.each do |what, (sql, deparsed)|
      it "accepts #{what}" do
        expect(builds(sql).sql).to eq(deparsed)
      end
    end

    it "accepts trigram GIN and GiST indexes, with operator class parameters" do
      conn.exec("CREATE EXTENSION pg_trgm")
      expect(builds("CREATE INDEX ON public.customers USING gin (email gin_trgm_ops)").sql)
        .to eq("CREATE INDEX ON public.customers USING gin (email gin_trgm_ops)")
      expect(builds("CREATE INDEX ON public.customers USING gist (lower(email) gist_trgm_ops(siglen=32))").sql)
        .to eq("CREATE INDEX ON public.customers USING gist (lower(email) gist_trgm_ops(siglen=32))")
    end

    # IF NOT EXISTS needs a name, and the name is dropped, so it goes too.
    it "accepts IF NOT EXISTS, and drops it along with the name" do
      expect(builds("CREATE INDEX IF NOT EXISTS orders_status_idx ON public.orders (status)").sql)
        .to eq("CREATE INDEX ON public.orders USING btree (status)")
    end

    it "drops comments" do
      expect(check("/* hint */ CREATE INDEX ON public.orders (status) -- why\n").sql)
        .to eq("CREATE INDEX ON public.orders USING btree (status)")
    end

    it "accepts a table named with quotes, and names it unquoted" do
      conn.exec('CREATE TABLE sales."Line Items" (id int)')
      accepted = check('CREATE INDEX ON sales."Line Items" (id)', tables: [table_name("sales", "Line Items")])
      expect(accepted.sql).to eq('CREATE INDEX ON sales."Line Items" USING btree (id)')
      expect(accepted.table).to eq(table_name("sales", "Line Items"))
    end

    # The check refuses only volatile functions. Postgres refuses a stable
    # one when it builds the index, and HypoPG does too.
    it "accepts a stable function, which Postgres then refuses" do
      sql = "CREATE INDEX ON public.orders (status) WHERE created_at > now()"
      expect(check(sql).sql).to eq("CREATE INDEX ON public.orders USING btree (status) WHERE created_at > now()")
      expect { conn.exec(check(sql).sql) }.to raise_error(PG::InvalidObjectDefinition, /must be marked IMMUTABLE/)
    end
  end

  describe "a statement that doesn't parse" do
    it "is refused as unparsable, without quoting pg_query's message" do
      expect { check("CREATE INDEX ON public.orders (status) WHERE status = 'x' AND") }
        .to rejected("unparsable", "unparsable: the index DDL doesn't parse")
    end
  end

  describe "a statement that isn't exactly one CREATE INDEX" do
    it "refuses two statements, even two CREATE INDEXes" do
      expect { check("CREATE INDEX ON public.orders (status); CREATE INDEX ON public.orders (id)") }
        .to rejected("not_create_index", "not_create_index: 2 statements, not one")
    end

    it "refuses an empty statement" do
      expect { check("") }.to rejected("not_create_index", "not_create_index: 0 statements, not one")
    end

    {
      "DROP INDEX public.orders_customer_id_idx" => "DropStmt",
      "SELECT 1" => "SelectStmt",
      "CREATE TABLE public.x (id int)" => "CreateStmt",
      "ALTER TABLE public.orders ADD PRIMARY KEY (id)" => "AlterTableStmt",
      "REINDEX INDEX public.orders_customer_id_idx" => "ReindexStmt"
    }.each do |sql, type|
      it "refuses a #{type}" do
        expect { check(sql) }.to rejected("not_create_index", "not_create_index: #{type}, not IndexStmt")
      end
    end
  end

  describe "refused options" do
    {
      "concurrently" => ["CREATE INDEX CONCURRENTLY ON public.orders (status)", "CONCURRENTLY isn't allowed"],
      "unique" => ["CREATE UNIQUE INDEX ON public.orders (status)", "UNIQUE isn't allowed"],
      "nulls_not_distinct" => [
        "CREATE INDEX ON public.orders (status) NULLS NOT DISTINCT", "NULLS NOT DISTINCT isn't allowed"
      ],
      "tablespace" => ["CREATE INDEX ON public.orders (status) TABLESPACE pg_default", "TABLESPACE isn't allowed"],
      "on_only" => ["CREATE INDEX ON ONLY public.orders (status)", "ON ONLY isn't allowed"],
      # IndexCandidate can't hold them, so they'd be lost without a word.
      "storage_options" => [
        "CREATE INDEX ON public.orders (status) WITH (fillfactor = 70)", "WITH (...) isn't allowed"
      ]
    }.each do |rule, (sql, detail)|
      it "refuses #{rule}" do
        expect { check(sql) }.to rejected(rule, "#{rule}: #{detail}")
      end
    end
  end

  describe "the table" do
    it "refuses an unqualified name, without resolving it through the search path" do
      expect { check("CREATE INDEX ON orders (status)", { "search_path" => "public" }) }
        .to rejected("unqualified_table", "unqualified_table: orders isn't schema qualified")
    end

    it "refuses a table the query doesn't use, naming it" do
      expect { check("CREATE INDEX ON sales.refunds (id)") }
        .to rejected("unknown_relation", "unknown_relation: sales.refunds isn't a table the query uses")
    end

    it "compares the schema too" do
      conn.exec("CREATE TABLE sales.orders (status text)")
      expect { check("CREATE INDEX ON sales.orders (status)") }
        .to rejected("unknown_relation", "unknown_relation: sales.orders isn't a table the query uses")
    end

    it "refuses a name with a database in front" do
      expect { check("CREATE INDEX ON quaack.public.orders (status)") }
        .to rejected("unknown_relation", "unknown_relation: public.orders is named with a database")
    end

    it "comes back as the table the index is on, of those the query uses" do
      expect(check("CREATE INDEX ON public.customers (email)").table).to eq(table_name("public", "customers"))
      expect(check("CREATE INDEX ON sales.items (order_id)").table).to eq(table_name("sales", "items"))
    end

    it "takes the tables as an argument, such as a rewrite candidate's" do
      expect(check("CREATE INDEX ON sales.refunds (id)", tables: [table_name("sales", "refunds")]).sql)
        .to eq("CREATE INDEX ON sales.refunds USING btree (id)")
      expect { check("CREATE INDEX ON public.orders (id)", tables: [table_name("sales", "refunds")]) }
        .to rejected("unknown_relation")
    end
  end

  # What Postgres never allows in an index expression or predicate.
  describe "forbidden expressions" do
    {
      "a parameter in the predicate" => ["(status) WHERE status = $1", "the predicate uses a parameter"],
      "a parameter in a key" => ["((status || $1))", "a key expression uses a parameter"],
      "a subquery in the predicate" => [
        "(status) WHERE customer_id IN (SELECT id FROM public.customers)", "the predicate uses a subquery"
      ],
      "a subquery in a key" => ["(((SELECT 1)))", "a key expression uses a subquery"],
      "an aggregate in the predicate" => [
        "(status) WHERE total_cents > sum(total_cents)", "the predicate uses an aggregate, window, or grouping function"
      ],
      "a window function in a key" => [
        "((row_number() OVER ()))", "a key expression uses an aggregate, window, or grouping function"
      ],
      "count(*) in a key" => ["((count(*)))", "a key expression uses an aggregate, window, or grouping function"]
    }.each do |what, (tail, detail)|
      it "refuses #{what}" do
        expect { check("CREATE INDEX ON public.orders #{tail}") }
          .to rejected("forbidden_in_index", "forbidden_in_index: #{detail}")
      end
    end
  end

  # SupportedSql's list, applied to the key expressions and the predicate,
  # so the volatility check sees every call.
  describe "unsupported constructs" do
    it "refuses a row comparison in the predicate" do
      expect { check("CREATE INDEX ON public.orders (status) WHERE (id, status) > (1, 'x')") }
        .to rejected("unsupported_construct", "unsupported_construct: RowExpr")
    end

    it "refuses field selection in a key, which can call a function" do
      expect { check("CREATE INDEX ON public.orders (((public.orders).status))") }
        .to rejected("unsupported_construct", "unsupported_construct: A_Indirection other than array subscripts")
    end

    it "refuses an XML function in a key" do
      expect { check("CREATE INDEX ON public.orders ((xmlelement(name x, status)))") }
        .to rejected("unsupported_construct", "unsupported_construct: XmlExpr")
    end
  end

  # The 3d rule, with its conservative overload resolution.
  describe "volatile functions" do
    {
      "a key expression" => ["((random()))", "function pg_catalog.random is volatile"],
      "the predicate" => ["(status) WHERE random() < 0.5", "function pg_catalog.random is volatile"],
      "a nested call" => ["((lower(public.bump(status))))", "function public.bump is volatile"],
      "an operator" => ["(status) WHERE total_cents === 1", "operator public.=== calls volatile function public.jumpy"],
      "INCLUDE" => ["(status) INCLUDE ((clock_timestamp()))", "function pg_catalog.clock_timestamp is volatile"]
    }.each do |where, (tail, detail)|
      it "refuses one in #{where}" do
        expect { check("CREATE INDEX ON public.orders #{tail}") }
          .to rejected("volatile_function", "volatile_function: #{detail}")
      end
    end

    it "refuses attribute notation that calls a volatile function on the row" do
      conn.exec("CREATE FUNCTION public.evil3(public.orders) RETURNS int LANGUAGE sql VOLATILE AS $$SELECT 1$$")

      expect { check("CREATE INDEX ON public.orders ((orders.evil3))") }
        .to rejected("volatile_function", "volatile_function: function public.evil3 is volatile")
    end

    it "looks up an unqualified function in the plan's search path" do
      expect { check("CREATE INDEX ON public.orders ((bump(status)))", { "search_path" => "sales" }) }
        .to rejected("volatile_function", "volatile_function: function sales.bump is volatile")
    end

    it "refuses a bad search path" do
      expect { check("CREATE INDEX ON public.orders ((lower(status)))", { "search_path" => "public," }) }
        .to rejected("bad_search_path", "bad_search_path: search_path public, has an empty entry")
    end
  end

  describe "a statement pg_query deparses wrong" do
    # The deparser writes 't'::boolean as true, which parses to another
    # tree.
    it "is refused as deparse_mismatch" do
      expect { check("CREATE INDEX ON public.orders (status) WHERE 't'::boolean") }.to rejected("deparse_mismatch")
    end
  end

  describe "the order of the checks" do
    it "checks the statement before its options, and the options in order" do
      expect { check("CREATE UNIQUE INDEX CONCURRENTLY ON public.orders (id); SELECT 1") }
        .to rejected("not_create_index")
      sql = "CREATE UNIQUE INDEX CONCURRENTLY ON ONLY public.orders (id) NULLS NOT DISTINCT TABLESPACE t"
      expect { check(sql) }.to rejected("concurrently")
      expect { check(sql.sub("CONCURRENTLY ", "")) }.to rejected("unique")
      expect { check(sql.sub("UNIQUE INDEX CONCURRENTLY", "INDEX")) }.to rejected("nulls_not_distinct")
      expect { check(sql.sub("UNIQUE INDEX CONCURRENTLY", "INDEX").sub(" NULLS NOT DISTINCT", "")) }
        .to rejected("tablespace")
    end

    it "checks options before the table, and the table before the expressions" do
      expect { check("CREATE INDEX ON ONLY orders (status)") }.to rejected("on_only")
      expect { check("CREATE INDEX ON orders ((random())) WHERE status = $1") }.to rejected("unqualified_table")
      expect { check("CREATE INDEX ON sales.refunds ((random())) WHERE id = $1") }.to rejected("unknown_relation")
    end

    it "checks forbidden expressions, then supported SQL, then volatility, then the deparse" do
      expect { check("CREATE INDEX ON public.orders ((random())) WHERE (id, status) > ($1, 'x')") }
        .to rejected("forbidden_in_index")
      expect { check("CREATE INDEX ON public.orders ((random())) WHERE (id, status) > (1, 'x')") }
        .to rejected("unsupported_construct")
      expect { check("CREATE INDEX ON public.orders ((random())) WHERE 't'::boolean") }
        .to rejected("volatile_function")
    end
  end

  # The DDL is untrusted, and its predicate can hold real literals. Every
  # rejection's message, and the error line ErrorFilter makes of it, names
  # only the rule and shape-class names, so nothing else in the DDL comes
  # out.
  describe "a sentinel in the DDL" do
    sentinel = "SENTINEL-7b31f0"

    # DDL with the sentinel in a comment, the index name, a key expression's
    # literal, the predicate's literal, and a line comment, plus whatever
    # gets it refused.
    def self.planted(sentinel, head: "CREATE INDEX", table: "public.orders", key: "", tail: "")
      "/* #{sentinel} */ #{head} \"#{sentinel}\" ON #{table} ((status || '#{sentinel}')#{key}) " \
        "WHERE status <> '#{sentinel}'#{tail} -- #{sentinel}\n"
    end

    # The refusal's message and error line, once the refusal is checked to
    # be for rule.
    def refusal(sql, rule, settings = nil)
      error = nil
      expect { check(sql, settings) }.to(rejected(rule) { |raised| error = raised })
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "5a-5")
      expect(line).to include(%("rule":"#{rule}"))
      [error.message, line]
    end

    {
      "unparsable" => planted(sentinel, tail: " '#{sentinel}'"),
      "not_create_index" => "#{planted(sentinel)}; SELECT '#{sentinel}'",
      "concurrently" => planted(sentinel, head: "CREATE INDEX CONCURRENTLY"),
      "unique" => planted(sentinel, head: "CREATE UNIQUE INDEX"),
      "nulls_not_distinct" => planted(sentinel).sub(") WHERE", ") NULLS NOT DISTINCT WHERE"),
      "tablespace" => planted(sentinel).sub(") WHERE", ") TABLESPACE pg_default WHERE"),
      "on_only" => planted(sentinel, table: "ONLY public.orders"),
      "storage_options" => planted(sentinel).sub(") WHERE", ") WITH (fillfactor = 70) WHERE"),
      "unqualified_table" => planted(sentinel, table: "orders"),
      "unknown_relation" => planted(sentinel, table: "sales.refunds"),
      "forbidden_in_index" => planted(sentinel, tail: " AND status = $1"),
      "unsupported_construct" => planted(sentinel, tail: " AND (id, status) > (1, 'x')"),
      "volatile_function" => planted(sentinel, key: ", (random())"),
      "deparse_mismatch" => planted(sentinel, tail: " AND 't'::boolean")
    }.each do |rule, sql|
      it "never shows up when it's refused as #{rule}" do
        expect(sql.scan(sentinel).size).to be >= 5
        refusal(sql, rule).each { |text| expect(text).not_to include(sentinel) }
      end
    end

    it "never shows up when it's refused as bad_search_path" do
      refusal(self.class.planted(sentinel), "bad_search_path", { "search_path" => "public," })
        .each { |text| expect(text).not_to include(sentinel) }
    end

    it "is accepted, literals and all, but not the name, when nothing is wrong" do
      accepted = check(self.class.planted(sentinel))
      expect(accepted.sql).to eq(
        "CREATE INDEX ON public.orders USING btree ((status || '#{sentinel}')) WHERE status <> '#{sentinel}'"
      )
    end

    # Table names are shape, so a message may name them. This proves the
    # message assertions above would catch a sentinel that got in. The error
    # line never carries a message, so it stays clean even then.
    it "is caught when it's in a name the message is allowed to name" do
      message, line = refusal(self.class.planted(sentinel, table: %(sales."#{sentinel}")), "unknown_relation")
      expect(message).to include(sentinel)
      expect(line).not_to include(sentinel)
    end
  end
end
