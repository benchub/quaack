# frozen_string_literal: true

require "quaack/enclave/rewrite_candidate_check"
require "quaack/enclave/error_filter"

# Every example runs against real Postgres, since the relation and
# volatility checks read the production catalog. Each one gets a fresh copy
# of the sample schema (public.customers and public.orders), plus a sales
# schema with a second table, and relations of every kind but a plain table.
RSpec.describe Quaack::Enclave::RewriteCandidateCheck do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  # What the original query uses: public.orders, public.customers, and
  # sales.items, with three placeholders.
  let(:relations) { [table_name("public", "orders"), table_name("public", "customers"), table_name("sales", "items")] }
  let(:original) { described_class::Original.new(relations:, placeholders: 3) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.items (id int, order_id bigint, qty int);
      CREATE VIEW public.order_view AS SELECT id, status FROM public.orders;
      CREATE VIEW public.random_view AS SELECT id, random() AS r FROM public.orders;
      CREATE MATERIALIZED VIEW public.order_mv AS SELECT id, status FROM public.orders;
      CREATE TABLE public.parted (id int) PARTITION BY RANGE (id);
      CREATE FUNCTION public.bump() RETURNS int LANGUAGE sql VOLATILE AS $$SELECT 1$$;
      CREATE FUNCTION public.steady() RETURNS int LANGUAGE sql IMMUTABLE AS $$SELECT 1$$;
    SQL
  end

  def check(sql, settings = nil, original: self.original) = described_class.check(sql, original, settings, conn)

  # The Error for rule, with message if given, and no cause. The block, if
  # any, gets the error too.
  def rejected(rule, message = nil, &also)
    raise_error(described_class::Error) do |error|
      expect([error.rule, error.cause]).to eq([rule, nil])
      expect(error.message).to eq(message || error.message).and start_with("#{rule}: ")
      also&.call(error)
    end
  end

  describe "an acceptable candidate" do
    it "comes back qualified, with its parse" do
      sql = <<~SQL
        SELECT o.id, i.qty FROM orders o JOIN sales.items i ON i.order_id = o.id
        WHERE o.status = $1 AND o.total_cents > $3 LIMIT 1
      SQL
      accepted = check(sql)

      expect(accepted).to be_a(described_class::Accepted)
      expect(accepted.sql).to eq(
        "SELECT o.id, i.qty FROM public.orders o JOIN sales.items i ON i.order_id = o.id " \
        "WHERE o.status = $1 AND o.total_cents > $3 LIMIT 1"
      )
      expect(accepted.parse.deparse).to eq(accepted.sql)
    end

    it "may drop a relation the original uses, since a rewrite can eliminate a join" do
      expect(check("SELECT id FROM public.orders WHERE status = $1").sql)
        .to eq("SELECT id FROM public.orders WHERE status = $1")
    end

    it "may add constants of its own, such as LIMIT 1 or COALESCE(x, 0)" do
      sql = "SELECT coalesce(total_cents, 0), true, NULL, 'x' FROM orders LIMIT 1"
      expect(check(sql).sql).to eq("SELECT COALESCE(total_cents, 0), true, NULL, 'x' FROM public.orders LIMIT 1")
    end

    it "may use a CTE, whose name isn't a relation" do
      sql = "WITH recent AS (SELECT id FROM orders WHERE id > $2) SELECT id FROM recent"
      expect(check(sql).sql).to eq("WITH recent AS (SELECT id FROM public.orders WHERE id > $2) SELECT id FROM recent")
    end

    it "may use a keyset row comparison" do
      sql = "SELECT id FROM orders WHERE (total_cents, id) < ($1, $2) ORDER BY total_cents DESC, id DESC LIMIT 10"
      expect(check(sql).sql).to eq(
        "SELECT id FROM public.orders WHERE (total_cents, id) < ($1, $2) ORDER BY total_cents DESC, id DESC LIMIT 10"
      )
    end

    it "may call an immutable user function" do
      expect(check("SELECT public.steady() FROM orders").sql).to eq("SELECT public.steady() FROM public.orders")
    end
  end

  describe "a candidate that doesn't parse" do
    it "is refused as unparsable, without quoting pg_query's message" do
      expect { check("SELECT 'x' FROM") }
        .to rejected("unparsable", "unparsable: the candidate doesn't parse")
    end
  end

  # SupportedSql does these checks. They're pinned here too, since they're
  # what README's "What goes into the enclave" names for a rewrite
  # candidate, and they must hold even if the supported list changes.
  describe "a candidate that isn't exactly one plain SELECT" do
    it "refuses two statements" do
      expect { check("SELECT 1; SELECT 2") }
        .to rejected("unsupported_construct", "unsupported_construct: ParseResult with 2 statements, not one")
    end

    it "refuses an empty candidate" do
      expect { check("") }
        .to rejected("unsupported_construct", "unsupported_construct: ParseResult with 0 statements, not one")
    end

    it "refuses statements that aren't a SELECT" do
      expect { check("DELETE FROM orders") }.to rejected("unsupported_construct", "unsupported_construct: DeleteStmt")
      expect { check("UPDATE orders SET status = $1") }
        .to rejected("unsupported_construct", "unsupported_construct: UpdateStmt")
      expect { check("EXPLAIN SELECT 1") }.to rejected("unsupported_construct", "unsupported_construct: ExplainStmt")
    end

    it "refuses a data-modifying CTE" do
      expect { check("WITH d AS (DELETE FROM orders RETURNING id) SELECT id FROM d") }
        .to rejected("unsupported_construct", "unsupported_construct: DeleteStmt")
      expect { check("WITH i AS (INSERT INTO sales.items VALUES (1) RETURNING id) SELECT id FROM i") }
        .to rejected("unsupported_construct", "unsupported_construct: InsertStmt")
    end

    it "refuses SELECT INTO" do
      expect { check("SELECT id INTO copied FROM orders") }
        .to rejected("unsupported_construct", "unsupported_construct: IntoClause")
    end

    it "refuses a locking clause" do
      %w[UPDATE SHARE].each do |strength|
        expect { check("SELECT id FROM orders FOR #{strength}") }
          .to rejected("unsupported_construct", "unsupported_construct: LockingClause")
      end
    end
  end

  describe "placeholders" do
    it "accepts every placeholder from $1 to the original's count" do
      expect(check("SELECT $1, $2, $3 FROM orders").sql).to eq("SELECT $1, $2, $3 FROM public.orders")
    end

    it "refuses a placeholder above the original's count" do
      expect { check("SELECT id FROM orders WHERE id = $4") }
        .to rejected("bad_placeholder", "bad_placeholder: $4 isn't one of the original's $1 to $3")
    end

    it "refuses $0, and a number too big for an int" do
      expect { check("SELECT $0") }
        .to rejected("bad_placeholder", "bad_placeholder: $0 isn't one of the original's $1 to $3")
      expect { check("SELECT $2147483648") }
        .to rejected("bad_placeholder", "bad_placeholder: $-2147483648 isn't one of the original's $1 to $3")
    end

    it "refuses every placeholder when the original has none" do
      none = described_class::Original.new(relations:, placeholders: 0)
      expect { check("SELECT $1 FROM orders", original: none) }
        .to rejected("bad_placeholder", "bad_placeholder: $1 isn't allowed, since the original has no placeholders")
    end

    {
      "the select list" => ["SELECT $1, $9 FROM orders", 9],
      "a keyset row comparison" => ["SELECT id FROM orders WHERE (total_cents, id) < ($1, $4)", 4],
      "a subquery" => ["SELECT $2 FROM orders WHERE id IN (SELECT id FROM orders WHERE id = $3 OR id = $5)", 5]
    }.each do |where, (sql, bad)|
      it "finds a bad placeholder after good ones, in #{where}" do
        expect { check(sql) }
          .to rejected("bad_placeholder", "bad_placeholder: $#{bad} isn't one of the original's $1 to $3")
      end
    end

    it "finds a placeholder anywhere in the candidate" do
      expect { check("WITH c AS (SELECT id FROM orders WHERE id IN (SELECT $9)) SELECT id FROM c") }
        .to rejected("bad_placeholder", "bad_placeholder: $9 isn't one of the original's $1 to $3")
    end
  end

  describe "relations" do
    it "refuses a table the original doesn't use, naming it" do
      conn.exec("CREATE TABLE sales.refunds (id int)")
      expect { check("SELECT id FROM sales.refunds") }
        .to rejected("unknown_relation", "unknown_relation: sales.refunds isn't a relation the original uses")
    end

    it "resolves an unqualified name with the plan's search path before comparing" do
      conn.exec("CREATE TABLE sales.orders (id int)")
      expect { check("SELECT id FROM orders", { "search_path" => "sales, public" }) }
        .to rejected("unknown_relation", "unknown_relation: sales.orders isn't a relation the original uses")
      expect(check("SELECT id FROM orders").sql).to eq("SELECT id FROM public.orders")
    end

    it "refuses a relation that doesn't exist" do
      expect { check("SELECT id FROM nowhere") }
        .to rejected("unknown_relation", "unknown_relation: relation nowhere isn't schema qualified, and no schema " \
                                         "in the search path (pg_catalog, postgres, public) has it")
      expect { check("SELECT id FROM public.nowhere") }
        .to rejected("unknown_relation", "unknown_relation: public.nowhere isn't a relation the original uses")
    end

    it "reads the relkind of the relation in its own schema, not another of the same name" do
      conn.exec("CREATE VIEW sales.orders AS SELECT id FROM public.orders")
      both = described_class::Original.new(relations: [table_name("public", "orders"), table_name("sales", "orders")],
                                           placeholders: 0)

      expect(check("SELECT id FROM public.orders", original: both).sql).to eq("SELECT id FROM public.orders")
      expect { check("SELECT id FROM sales.orders", original: both) }
        .to rejected("not_a_table", "not_a_table: sales.orders has relkind v, not r")
    end

    {
      "a join" => "SELECT o.id FROM public.orders o JOIN public.order_view v ON v.id = o.id",
      "a subquery" => "SELECT id FROM orders WHERE id IN (SELECT id FROM order_view)"
    }.each do |where, sql|
      it "refuses a view that comes after a table, in #{where}" do
        mixed = described_class::Original.new(
          relations: [table_name("public", "orders"), table_name("public", "order_view")], placeholders: 0
        )
        expect { check(sql, original: mixed) }
          .to rejected("not_a_table", "not_a_table: public.order_view has relkind v, not r")
      end
    end

    it "refuses a relation the original names that doesn't exist" do
      missing = described_class::Original.new(relations: [table_name("public", "gone")], placeholders: 0)
      expect { check("SELECT 1 FROM public.gone", original: missing) }
        .to rejected("unknown_relation", "unknown_relation: public.gone doesn't exist")
    end

    it "refuses a relation hidden in a subquery or CTE" do
      conn.exec("CREATE TABLE sales.refunds (id int)")
      expect { check("WITH c AS (SELECT id FROM orders WHERE id IN (SELECT id FROM sales.refunds)) SELECT id FROM c") }
        .to rejected("unknown_relation", "unknown_relation: sales.refunds isn't a relation the original uses")
    end

    it "refuses a bad search path" do
      expect { check("SELECT id FROM orders", { "search_path" => "public," }) }
        .to rejected("bad_search_path", "bad_search_path: search_path public, has an empty entry")
    end

    # The original's relation set comes from 3a, which should hold only
    # tables, but the check doesn't rely on that: a view's body could call a
    # volatile function the volatility check never sees.
    describe "that aren't plain tables, even when the original uses them" do
      let(:relations) do
        %w[order_view random_view order_mv parted orders_id_seq].map { |name| table_name("public", name) }
      end

      {
        "order_view" => "v", "random_view" => "v", "order_mv" => "m", "parted" => "p", "orders_id_seq" => "S"
      }.each do |name, relkind|
        it "refuses #{name}, whose relkind is #{relkind}" do
          expect { check("SELECT * FROM #{name}") }
            .to rejected("not_a_table", "not_a_table: public.#{name} has relkind #{relkind}, not r")
        end
      end
    end
  end

  # The volatility check (3d) runs on every candidate. These are the calls
  # the arena runner relies on it to refuse, since their effects outlive
  # the transaction or change the session.
  describe "volatile functions" do
    {
      "set_config('statement_timeout', '0', false)" => "function pg_catalog.set_config is volatile",
      "pg_advisory_lock(1)" => "function pg_catalog.pg_advisory_lock is volatile",
      "lo_import('/x')" => "function pg_catalog.lo_import is volatile",
      "nextval('orders_id_seq')" => "function pg_catalog.nextval is volatile",
      "random()" => "function pg_catalog.random is volatile",
      "public.bump()" => "function public.bump is volatile",
      "bump()" => "function public.bump is volatile"
    }.each do |call, detail|
      it "refuses #{call}" do
        expect { check("SELECT #{call} FROM orders") }.to rejected("volatile_function", "volatile_function: #{detail}")
      end
    end

    it "refuses one hidden in a CTE's WHERE" do
      expect { check("WITH c AS (SELECT id FROM orders WHERE random() > $1) SELECT id FROM c") }
        .to rejected("volatile_function", "volatile_function: function pg_catalog.random is volatile")
    end
  end

  # pg_query's deparser can write SQL that means something else, so a
  # qualified candidate must parse back to the tree it came from.
  describe "a candidate pg_query deparses wrong" do
    # The deparser writes 't'::boolean as true, which parses to another
    # tree.
    it "is refused when it would parse back as another tree" do
      expect { check("SELECT id FROM orders WHERE 't'::boolean") }.to rejected("deparse_mismatch")
    end

    # pg_query alone would drop these parentheses. Deparse keeps them
    # (20260924-4).
    it "is accepted when Deparse adds the parentheses pg_query leaves out" do
      expect(check("SELECT id FROM orders WHERE (status = $1) IS NOT DISTINCT FROM (true AND false)").sql)
        .to eq("SELECT id FROM public.orders WHERE status = $1 IS NOT DISTINCT FROM (true AND false)")
      expect(check("SELECT (ARRAY(SELECT id FROM orders))[1]").sql)
        .to eq("SELECT (ARRAY(SELECT id FROM public.orders))[1]")
    end
  end

  describe "the order of the checks" do
    it "checks supported SQL before placeholders" do
      expect { check("SELECT $9 FROM orders FOR UPDATE") }
        .to rejected("unsupported_construct", "unsupported_construct: LockingClause")
    end

    it "checks placeholders before relations, and relations before volatility" do
      expect { check("SELECT random(), $7 FROM public.nowhere") }.to rejected("bad_placeholder")
      expect { check("SELECT random() FROM public.nowhere") }.to rejected("unknown_relation")
    end
  end

  # The candidate is untrusted, and can hold anything. Every rejection's
  # message, and the error line ErrorFilter makes of it, names only the rule
  # and shape-class names, so nothing else in the candidate comes out.
  describe "a sentinel in the candidate" do
    sentinel = "SENTINEL-c4d1e9"

    before do
      conn.exec("CREATE TABLE sales.refunds (id int)")
      conn.exec("CREATE VIEW sales.item_view AS SELECT id FROM sales.items")
    end

    let(:relations) do
      [table_name("public", "orders"), table_name("sales", "items"), table_name("sales", "item_view")]
    end

    # A candidate with the sentinel in a comment, a string literal, a quoted
    # column alias, a cast's literal, a quoted table alias, a line comment,
    # and a comparison, plus whatever gets it refused.
    def self.planted(sentinel, from: "orders", extra: "", tail: "")
      "/* #{sentinel} */ SELECT '#{sentinel}' AS \"#{sentinel}\", '#{sentinel}'::text#{extra} " \
        "FROM #{from} AS \"#{sentinel}a\" -- #{sentinel}\nWHERE 'x' <> '#{sentinel}'#{tail}"
    end

    # The refusal's message and error line, once the refusal is checked to
    # be for rule.
    def refusal(sql, rule)
      error = nil
      expect { check(sql) }.to(rejected(rule) { |raised| error = raised })
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "6a")
      expect(line).to include(%("rule":"#{rule}"))
      [error.message, line]
    end

    {
      "unparsable" => planted(sentinel, tail: " FROM"),
      "unsupported_construct" => planted(sentinel, tail: " FOR UPDATE"),
      "bad_placeholder" => planted(sentinel, extra: ", $8"),
      "unknown_relation" => planted(sentinel, from: "sales.refunds"),
      "not_a_table" => planted(sentinel, from: "sales.item_view"),
      "deparse_mismatch" => planted(sentinel, tail: " AND ('x' = $1) IS NOT DISTINCT FROM (true AND 't'::boolean)"),
      "volatile_function" => planted(sentinel, extra: ", random()")
    }.each do |rule, sql|
      it "never shows up when it's refused as #{rule}" do
        expect(sql.scan(sentinel).size).to eq(7)
        refusal(sql, rule).each { |text| expect(text).not_to include(sentinel) }
      end
    end

    it "is accepted, literals and all, when nothing is wrong" do
      expect(check(self.class.planted(sentinel)).sql).to include(sentinel)
    end

    # Relation names are shape, so a message may name them. This proves the
    # message assertions above would catch a sentinel that got in. The error
    # line never carries a message, so it stays clean even then.
    it "is caught when it's in a name the message is allowed to name" do
      conn.exec(%(CREATE TABLE sales."#{sentinel}" (id int)))
      message, line = refusal(%(SELECT id FROM sales."#{sentinel}"), "unknown_relation")
      expect(message).to include(sentinel)
      expect(line).not_to include(sentinel)
    end
  end
end
