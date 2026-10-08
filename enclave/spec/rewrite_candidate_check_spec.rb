# frozen_string_literal: true

require "quaack/enclave/rewrite_candidate_check"
require "quaack/enclave/error_filter"
require_relative "support/catalog_shadow"

# Every example runs against real Postgres, since the relation and
# volatility checks read the production catalog. Each one gets a fresh copy
# of the sample schema (public.customers and public.orders), plus a sales
# schema with a second table, and relations of every kind but a plain table.
RSpec.describe Quaack::Enclave::RewriteCandidateCheck do
  let(:conn) { test_database.connection }

  def table_name(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  # What the original query uses: public.orders, public.customers, and
  # sales.items, with three placeholders. Its SQL gives the user functions,
  # the domain, and the bare operators and types the examples use, since a
  # candidate may use only the original's names and pg_catalog's, and pins
  # a new bare one to pg_catalog (see "functions, types, collations, and
  # operators").
  let(:relations) { [table_name("public", "orders"), table_name("public", "customers"), table_name("sales", "items")] }
  let(:original_sql) do
    "SELECT public.steady(), public.bump(), public.ids(), $1::regclass, $2::text, $3::name, $1::public.reg_dom " \
      "FROM public.orders WHERE id = $1 AND id > $2 AND id < $3 AND id - $1 IS NULL"
  end
  let(:original) { described_class::Original.new(relations:, placeholders: 3, sql: original_sql) }

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

    # Task 20260926-56 qualified a bare function only one schema has, as
    # the original's are. Since 20261008-32, a bare name gets the schema the
    # original writes it with, or else pg_catalog.
    it "gives a bare function the original's schema for it, or else pg_catalog" do
      expect(check("SELECT steady(), lower(status), shout() FROM orders").sql)
        .to eq("SELECT public.steady(), pg_catalog.lower(status), pg_catalog.shout() FROM public.orders")
      expect { check("SELECT 'lower'::regproc FROM orders") }.to rejected("unsupported_reg_literal")
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
        .to rejected("unparsable", "unparsable: the candidate doesn't parse #{PARSER_NOTE}")
    end
  end

  # SupportedSql does these checks. They're pinned here too, since they're
  # what DESIGN.md's "What goes into the enclave" names for a rewrite
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
      "the select list, before good ones" => ["SELECT $9, $1, $2 FROM orders", 9],
      "a keyset row comparison" => ["SELECT id FROM orders WHERE (total_cents, id) < ($1, $4)", 4],
      "a subquery" => ["SELECT $2 FROM orders WHERE id IN (SELECT id FROM orders WHERE id = $3 OR id = $5)", 5]
    }.each do |where, (sql, bad)|
      it "finds a bad placeholder among good ones, in #{where}" do
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
                                         'in the search path ("pg_catalog", "postgres", "public") has it')
      expect { check("SELECT id FROM public.nowhere") }
        .to rejected("unknown_relation", "unknown_relation: public.nowhere isn't a relation the original uses")
    end

    it "reads the relkind of the relation in its own schema, not another of the same name" do
      conn.exec("CREATE VIEW sales.orders AS SELECT id FROM public.orders")
      both = described_class::Original.new(relations: [table_name("public", "orders"), table_name("sales", "orders")],
                                           placeholders: 0)

      expect(check("SELECT id FROM public.orders", original: both).sql).to eq("SELECT id FROM public.orders")
      expect { check("SELECT id FROM sales.orders", original: both) }
        .to rejected("view_relation", "view_relation: sales.orders is a view (relkind v), not a plain table")
    end

    {
      "a join" => "SELECT o.id FROM public.orders o JOIN public.order_view v ON v.id = o.id",
      "a join, before the table" => "SELECT v.id FROM public.order_view v JOIN public.orders o ON v.id = o.id",
      "a subquery" => "SELECT id FROM orders WHERE id IN (SELECT id FROM order_view)"
    }.each do |where, sql|
      it "refuses a view alongside a table, in #{where}" do
        mixed = described_class::Original.new(
          relations: [table_name("public", "orders"), table_name("public", "order_view")], placeholders: 0
        )
        expect { check(sql, original: mixed) }
          .to rejected("view_relation", "view_relation: public.order_view is a view (relkind v), not a plain table")
      end
    end

    # Task 20261007-9: public's comparisons, ahead of pg_catalog's on the
    # search_path, say no (see CatalogShadow), so an unqualified relkind
    # read would find no relation at all.
    it "reads the relkind when public's comparison operators shadow pg_catalog's" do
      conn.exec("SET search_path = public, pg_catalog")
      CatalogShadow.plant(conn, :operators)
      ordered, viewed = %w[orders order_view].map do |name|
        described_class::Original.new(relations: [table_name("public", name)], placeholders: 0)
      end

      expect(check("SELECT id FROM public.orders", original: ordered).sql).to eq("SELECT id FROM public.orders")
      expect { check("SELECT id FROM public.order_view", original: viewed) }
        .to rejected("view_relation", "view_relation: public.order_view is a view (relkind v), not a plain table")
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

    # The original's relation set comes from qualify, which should hold only
    # tables, but the check doesn't rely on that: a view's body could call a
    # volatile function the volatility check never sees.
    describe "that aren't plain tables, even when the original uses them" do
      let(:relations) do
        %w[order_view random_view order_mv parted orders_id_seq].map { |name| table_name("public", name) }
      end

      # Task 20260923-57: the same per-kind rules intake uses (Relations).
      {
        "order_view" => ["v", "view_relation", "a view"],
        "random_view" => ["v", "view_relation", "a view"],
        "order_mv" => ["m", "matview_relation", "a materialized view"],
        "parted" => ["p", "partitioned_relation", "a partitioned table"],
        "orders_id_seq" => ["S", "sequence_relation", "a sequence"]
      }.each do |name, (relkind, rule, kind)|
        it "refuses #{name}, whose relkind is #{relkind}, as #{rule}" do
          expect { check("SELECT * FROM #{name}") }
            .to rejected(rule, "#{rule}: public.#{name} is #{kind} (relkind #{relkind}), not a plain table")
        end
      end
    end

    # A relation outside the original's set is refused for that alone, so
    # the refusal doesn't say what kind of relation it is.
    it "refuses a view the original doesn't use as unknown_relation, not by its kind" do
      expect { check("SELECT id FROM public.order_view") }
        .to rejected("unknown_relation", "unknown_relation: public.order_view isn't a relation the original uses")
    end

    it "refuses a user function in FROM, as intake does" do
      conn.exec("CREATE FUNCTION public.ids() RETURNS SETOF int LANGUAGE sql IMMUTABLE AS $$SELECT 1$$")
      expect { check("SELECT * FROM public.ids() AS i JOIN orders o ON o.id = i") }
        .to rejected("user_function_in_from", "user_function_in_from: a function in FROM isn't in pg_catalog")
    end
  end

  # The volatility check (volatility) runs on every candidate. These are the calls
  # the arena runner relies on it to refuse, since their effects outlive
  # the transaction or change the session.
  describe "volatile functions" do
    {
      "set_config('statement_timeout', '0', false)" => "function pg_catalog.set_config is volatile",
      "pg_advisory_lock(1)" => "function pg_catalog.pg_advisory_lock is volatile",
      "lo_import('/x')" => "function pg_catalog.lo_import is volatile",
      "nextval('orders_id_seq')" => "function pg_catalog.nextval is volatile",
      "random()" => "function pg_catalog.random is volatile",
      "public.bump()" => "function public.bump is volatile"
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

  # Task 20261008-31: Postgres reads a reg literal's text through the
  # catalog when it parses the query, so whether a candidate with one plans
  # would say whether the name exists. The original's literals are
  # redacted, so the LLM keeps one as its $n.
  describe "reg literals" do
    let(:message) { "unsupported_reg_literal: a reg type's value can come only from the original's $n in v1" }

    %w[regclass regtype regproc regprocedure regoper regoperator regnamespace regrole regcollation regconfig
       regdictionary].each do |type|
      it "refuses a #{type} literal" do
        expect { check("SELECT 'x'::#{type} FROM orders") }.to rejected("unsupported_reg_literal", message)
      end
    end

    {
      "with pg_catalog's schema" => "'public.orders'::pg_catalog.regclass",
      "as an array" => "'{public.orders}'::regclass[]",
      "written as CAST" => "CAST('public.orders' AS regclass)",
      "written as a typed literal" => "regclass 'public.orders'",
      "written with a quoted type name" => %('public.orders'::"regclass"),
      "deep in the query" => "(SELECT 1 WHERE coalesce('english'::regconfig, NULL) IS NULL)"
    }.each do |form, literal|
      it "refuses one #{form}" do
        expect { check("SELECT #{literal} FROM orders") }.to rejected("unsupported_reg_literal", message)
      end
    end

    it "accepts the original's own, as its $n" do
      expect(check("SELECT $1::regclass, id FROM orders").sql).to eq("SELECT $1::regclass, id FROM public.orders")
    end

    it "accepts a literal cast to a type that isn't a reg type" do
      expect(check("SELECT 'public.orders'::text, 'x'::name FROM orders").sql)
        .to eq("SELECT 'public.orders'::text, 'x'::name FROM public.orders")
    end
  end

  # Task 20261008-31's fix round: a reg value that doesn't come from a
  # direct cast of a literal. Each form names a relation that exists but
  # the original doesn't use, and one that's missing, and gets the same
  # refusal for both, before anything evaluates it.
  describe "reg values from elsewhere" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA hidden_sentinel; CREATE TABLE hidden_sentinel.secret_sentinel (id int);
        CREATE DOMAIN public.reg_dom AS regclass
      SQL
    end

    let(:names) { %w[hidden_sentinel.secret_sentinel hidden_sentinel.nothere_sentinel] }

    # The outcome of the form with each name in place of X, once it's
    # checked to be the same for both, and to name neither.
    def same_outcome(form, original: self.original)
      outcomes = names.map { outcome(form.gsub("X", it), original) }
      expect(outcomes.uniq.size).to eq(1), "#{form}: #{outcomes.inspect}"
      expect(outcomes.first.to_s).not_to include("sentinel")
      outcomes.first
    end

    def outcome(sql, original)
      check(sql, original:)
      "accepted"
    rescue described_class::Error => e
      [e.rule, e.message, e.cause]
    end

    reg_message = "a reg type's value can come only from the original's $n in v1"

    {
      "a function's regclass argument" => "SELECT pg_relation_filenode('X') FROM orders",
      "COALESCE with a $n" => "SELECT COALESCE($1::regclass, 'X') FROM orders",
      "CASE with a $n" => "SELECT CASE WHEN id > 0 THEN $1::regclass ELSE 'X' END FROM orders",
      "GREATEST with a $n" => "SELECT GREATEST($1::regclass, 'X') FROM orders",
      "VALUES with a $n" => "SELECT v FROM orders, (VALUES ($1::regclass), ('X')) AS w(v)",
      "a UNION with a $n" => "SELECT $1::regclass FROM orders UNION SELECT 'X' FROM orders",
      "a function's regconfig argument" => "SELECT to_tsvector('X', status) FROM orders",
      "an array of regclass" => "SELECT array_cat(ARRAY[$1::regclass], '{X}') FROM orders",
      "a cast to a domain over regclass" => "SELECT 'X'::public.reg_dom FROM orders",
      "a cast through text" => "SELECT 'X'::text::regclass FROM orders",
      "a cast through varchar and text" => "SELECT CAST('X' AS varchar)::text::regclass FROM orders",
      "a column cast" => "SELECT status::regclass FROM orders WHERE status = 'X'",
      "a cast function" => "SELECT regclass('X'::text) FROM orders",
      "pg_catalog's cast function" => "SELECT pg_catalog.regtype('X'::text) FROM orders"
    }.each do |form, sql|
      it "refuses #{form} the same way whatever it names" do
        expect(same_outcome(sql)).to eq(["unsupported_reg_literal", "unsupported_reg_literal: #{reg_message}", nil])
      end
    end

    {
      "has_table_privilege" => "SELECT has_table_privilege('X', 'SELECT') FROM orders",
      "to_regclass" => "SELECT id FROM orders WHERE to_regclass('X') IS NULL",
      "pg_get_serial_sequence" => "SELECT pg_catalog.pg_get_serial_sequence('X', 'id') FROM orders",
      "pg_input_is_valid" => "SELECT pg_input_is_valid('X', 'regclass') FROM orders"
    }.each do |function, sql|
      it "refuses a call to #{function} the same way whatever it names" do
        expect(same_outcome(sql)).to eq(
          ["name_lookup_function",
           "name_lookup_function: #{function} looks up a name, and the original doesn't make the same call", nil]
        )
      end
    end

    it "refuses a string literal whose type Postgres can't work out the same way whatever it holds" do
      expect(same_outcome("SELECT id FROM orders WHERE 'X' IS NULL")).to eq(
        ["untyped_literal", "untyped_literal: the candidate doesn't prepare with its string literals as parameters",
         nil]
      )
    end

    it "accepts a name lookup the original makes, as the original makes it" do
      original = described_class::Original.new(
        relations:, placeholders: 1, sql: "SELECT id FROM public.orders WHERE to_regclass($1) IS NULL"
      )
      expect(check("SELECT id FROM orders WHERE to_regclass($1) IS NULL", original:).sql)
        .to eq("SELECT id FROM public.orders WHERE to_regclass($1) IS NULL")
      expect(same_outcome("SELECT id FROM orders WHERE to_regclass('X') IS NULL", original:).first)
        .to eq("name_lookup_function")
    end

    it "types the original's $n as the original does" do
      original = described_class::Original.new(relations:, placeholders: 1, param_types: [25])
      expect(check("SELECT $1 IS NULL, 'x' FROM orders", original:).sql)
        .to eq("SELECT $1 IS NULL, 'x' FROM public.orders")
      expect { check("SELECT $1 IS NULL, 'x' FROM orders") }.to rejected("untyped_literal")
    end

    # These read X as an oid, not a name, so they fail the same way for
    # both names, and needn't be refused.
    [
      "SELECT id FROM orders WHERE 'X' = $1::regclass",
      "SELECT id FROM orders WHERE $1::regclass = ANY('{X}')",
      "SELECT id FROM orders WHERE $1::regclass IN ('X')",
      "SELECT NULLIF($1::regclass, 'X') FROM orders",
      "SELECT id FROM orders WHERE tableoid = 'X'"
    ].each do |sql|
      it "accepts #{sql}, which fails to plan the same way whatever X names" do
        outcomes = names.map do |name|
          accepted = check(sql.gsub("X", name))
          conn.exec("EXPLAIN #{accepted.sql.gsub("$1", "'public.orders'::text")}")
          "plans"
        rescue PG::Error => e
          e.result.error_field(PG::PG_DIAG_SQLSTATE)
        end
        expect(outcomes).to eq(%w[22P02 22P02])
      end
    end

    it "accepts a candidate whose string literals are ordinary text" do
      sql = "SELECT id, 'x' AS label, COALESCE(status, '') FROM orders WHERE status LIKE 'a%' " \
            "AND created_at > now() - interval '1 day' AND created_at AT TIME ZONE 'UTC' < $2"
      expect(check(sql).sql).to eq(
        "SELECT id, 'x' AS label, COALESCE(status, '') FROM public.orders WHERE status LIKE 'a%' " \
        "AND created_at > (pg_catalog.now() - '1 day'::interval) AND created_at AT TIME ZONE 'UTC' < $2"
      )
    end

    it "accepts EXTRACT, whose field is a string literal" do
      expect(check("SELECT EXTRACT(year FROM created_at) FROM orders").sql)
        .to eq("SELECT extract ('year' FROM created_at) FROM public.orders")
    end
  end

  # Task 20261008-32: a candidate may use only the original's functions,
  # types, collations, and operators, and pg_catalog's. A name in another
  # schema is refused the same way whether it exists or not, and a bare
  # name the original doesn't use is pinned to pg_catalog, so a user
  # schema on the path, such as one named for a role, can never supply it.
  describe "functions, types, collations, and operators" do
    let(:role) { "sentinelrole_#{SecureRandom.hex(4)}" }
    let(:path) { { "search_path" => '"$user", public' } }
    let(:named) do
      described_class::Original.new(relations:, placeholders: 3,
                                    sql: "SELECT public.steady() FROM public.orders WHERE id = $1")
    end

    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA hidden_sentinel;
        CREATE FUNCTION hidden_sentinel.vfn_sentinel() RETURNS int LANGUAGE sql VOLATILE AS $$SELECT 1$$;
        CREATE FUNCTION hidden_sentinel.lower(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$SELECT 'x'$$;
        CREATE TYPE hidden_sentinel.type_sentinel AS (a int);
        CREATE COLLATION hidden_sentinel.coll_sentinel FROM "C";
        CREATE FUNCTION hidden_sentinel.eq(int, int) RETURNS bool LANGUAGE sql IMMUTABLE AS $$SELECT true$$;
        CREATE OPERATOR hidden_sentinel.=== (LEFTARG = int, RIGHTARG = int, FUNCTION = hidden_sentinel.eq);
        CREATE ROLE "#{role}"; CREATE SCHEMA "#{role}";
        CREATE FUNCTION "#{role}".fn_sentinel() RETURNS int LANGUAGE sql VOLATILE AS $$SELECT 1$$;
        CREATE FUNCTION "#{role}".lower(varchar) RETURNS text LANGUAGE sql IMMUTABLE AS $$SELECT 'x'$$;
      SQL
    end

    after do
      conn.exec(%(SET client_min_messages = warning; DROP SCHEMA IF EXISTS "#{role}" CASCADE; DROP ROLE "#{role}"))
    end

    def outcome(sql, original: named)
      check(sql, path, original:).sql
    rescue described_class::Error => e
      [e.message, Quaack::Enclave::ErrorFilter.to_egress(e, step: "llm-rewrites")]
    end

    it "refuses a name in another schema the same way, whether it exists or not" do
      candidates = [
        "SELECT hidden_sentinel.vfn_sentinel() FROM orders", "SELECT hidden_sentinel.nothere_sentinel() FROM orders",
        "SELECT \"#{role}\".fn_sentinel() FROM orders", "SELECT \"#{role}\".nothere_sentinel() FROM orders",
        "SELECT $1::hidden_sentinel.type_sentinel FROM orders",
        "SELECT $1::hidden_sentinel.nothere_sentinel FROM orders",
        "SELECT status COLLATE hidden_sentinel.coll_sentinel FROM orders",
        "SELECT status COLLATE hidden_sentinel.nothere_sentinel FROM orders",
        "SELECT id FROM orders WHERE id OPERATOR(hidden_sentinel.===) 1",
        "SELECT id FROM orders WHERE id OPERATOR(hidden_sentinel.=~=) 1",
        "SELECT id FROM orders ORDER BY id USING OPERATOR(hidden_sentinel.===)",
        "SELECT public.bump() FROM orders"
      ]
      outcomes = candidates.map { outcome(it) }

      expect(outcomes.uniq.size).to eq(1)
      message, line = outcomes.first
      expect(message).to eq("unknown_name: a rewrite may use only the original's functions, types, collations, " \
                            "and operators, and pg_catalog's")
      expect(line).to include('"rule":"unknown_name"')
      [message, line].each { expect(it).not_to include("sentinel") }
    end

    it "pins a bare name the original doesn't use to pg_catalog, so a user schema can't supply it" do
      expect(%w[fn_sentinel nothere_sentinel].map { outcome("SELECT #{it}() FROM orders") })
        .to eq(%w[fn_sentinel nothere_sentinel].map { "SELECT pg_catalog.#{it}() FROM public.orders" })
      expect(outcome("SELECT lower(status) FROM orders WHERE total_cents > $3"))
        .to eq("SELECT pg_catalog.lower(status) FROM public.orders WHERE total_cents OPERATOR(pg_catalog.>) $3")
    end

    it "pins bare types and collations too" do
      expect(outcome("SELECT $1::text, status COLLATE \"C\" FROM orders"))
        .to eq('SELECT $1::pg_catalog.text, status COLLATE pg_catalog."C" FROM public.orders')
    end

    it "keeps the original's names as written, its own user function included" do
      expect(outcome("SELECT public.steady() FROM orders WHERE id = $1"))
        .to eq("SELECT public.steady() FROM public.orders WHERE id = $1")
    end

    # The fix round of 20261008-32: the original's qualified query writes
    # its user names with their schema, and the LLM may write them bare.
    it "gives a bare name the schema the original writes it with" do
      conn.exec(<<~SQL)
        CREATE FUNCTION public.sim(text, text) RETURNS real LANGUAGE sql IMMUTABLE AS $$SELECT 1::real$$;
        CREATE FUNCTION public.close_to(text, text) RETURNS bool LANGUAGE sql IMMUTABLE AS $$SELECT true$$;
        CREATE OPERATOR public.%% (LEFTARG = text, RIGHTARG = text, FUNCTION = public.close_to);
      SQL
      trgm = described_class::Original.new(
        relations:, placeholders: 1,
        sql: "SELECT public.sim(status, $1) FROM public.orders WHERE status OPERATOR(public.%%) $1"
      )
      expect(outcome("SELECT sim(status, $1) FROM orders WHERE status %% $1", original: trgm))
        .to eq("SELECT public.sim(status, $1) FROM public.orders WHERE status OPERATOR(public.%%) $1")
    end

    it "refuses a bare name the original writes with more than one schema" do
      two = described_class::Original.new(
        relations:, placeholders: 1, sql: "SELECT public.steady(), sales.steady() FROM public.orders"
      )
      expect(outcome("SELECT steady() FROM orders", original: two).first).to start_with("unknown_name: ")
    end

    it "accepts names written in pg_catalog" do
      expect(outcome("SELECT pg_catalog.upper(status) FROM orders WHERE id OPERATOR(pg_catalog.<) $2"))
        .to eq("SELECT pg_catalog.upper(status) FROM public.orders WHERE id OPERATOR(pg_catalog.<) $2")
    end
  end

  describe "the order of the checks" do
    it "checks unknown names after reg literals, and before relations" do
      expect { check("SELECT 'x'::regclass, hidden.f() FROM orders") }.to rejected("unsupported_reg_literal")
      expect { check("SELECT hidden.f() FROM public.nowhere") }.to rejected("unknown_name")
    end

    it "checks reg literals after placeholders, and before relations" do
      expect { check("SELECT 'x'::regclass, $7 FROM orders") }.to rejected("bad_placeholder")
      expect { check("SELECT 'x'::regclass FROM public.nowhere") }.to rejected("unsupported_reg_literal")
    end

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
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "llm-rewrites")
      expect(line).to include(%("rule":"#{rule}"))
      [error.message, line]
    end

    {
      "unparsable" => planted(sentinel, tail: " FROM"),
      "unsupported_construct" => planted(sentinel, tail: " FOR UPDATE"),
      "bad_placeholder" => planted(sentinel, extra: ", $8"),
      "unknown_relation" => planted(sentinel, from: "sales.refunds"),
      "view_relation" => planted(sentinel, from: "sales.item_view"),
      "deparse_mismatch" => planted(sentinel, tail: " AND ('x' = $1) IS NOT DISTINCT FROM (true AND 't'::boolean)"),
      "volatile_function" => planted(sentinel, extra: ", random()")
    }.each do |rule, sql|
      it "never shows up when it's refused as #{rule}" do
        expect(sql.scan(sentinel).size).to eq(7)
        refusal(sql, rule).each { |text| expect(text).not_to include(sentinel) }
      end
    end

    # The refusal mustn't tell the LLM what a schema named for a role holds
    # (20260923-57's review): a name the original doesn't use is refused the
    # same way whether a role's schema has it or nothing does. The same goes
    # for a function only a role's schema has.
    describe 'with "$user" in the search path' do
      let(:role) { "sentinelrole_#{SecureRandom.hex(4)}" }
      let(:path) { { "search_path" => '"$user", public' } }

      before do
        conn.exec(<<~SQL)
          CREATE ROLE "#{role}"; CREATE SCHEMA "#{role}";
          CREATE TABLE "#{role}".secret_sentinel (id int);
          CREATE TABLE public.secret_sentinel (id int);
          CREATE TABLE public.other_sentinel (id int);
          CREATE FUNCTION "#{role}".secret_fn() RETURNS int LANGUAGE sql IMMUTABLE AS $$SELECT 1$$;
        SQL
      end

      after do
        conn.exec(%(SET client_min_messages = warning; DROP SCHEMA IF EXISTS "#{role}" CASCADE; DROP ROLE "#{role}"))
      end

      def rule_for(sql)
        check(sql, path)
        "accepted"
      rescue described_class::Error => e
        e.rule
      end

      it "refuses a relation a role's schema holds as it refuses one that's missing" do
        rules = %w[secret_sentinel other_sentinel nothere_sentinel].map { rule_for("SELECT id FROM #{it}") }
        expect(rules).to eq(%w[unknown_relation unknown_relation unknown_relation])
      end

      it "treats a function only a role's schema has as it treats one that's missing" do
        expect(rule_for("SELECT secret_fn() FROM orders")).to eq(rule_for("SELECT nothere_fn() FROM orders"))
      end

      # Task 20261008-31: a reg literal names a relation or a type in text
      # the relation check never sees. One that's hidden, missing, or in
      # another schema, even one the original uses, is refused the same
      # way, with the same message, and the sentinel never comes out.
      it "refuses a reg literal the same way whatever it names" do
        conn.exec(<<~SQL)
          CREATE SCHEMA hidden_sentinel; CREATE TABLE hidden_sentinel.secret_sentinel (id int);
          CREATE TYPE hidden_sentinel.secret_type AS (a int)
        SQL
        literals = [
          "'hidden_sentinel.secret_sentinel'::regclass", "'hidden_sentinel.nothere_sentinel'::regclass",
          "'secret_sentinel'::regclass", "'other_sentinel'::regclass", "'nothere_sentinel'::regclass",
          "'public.orders'::regclass", "'hidden_sentinel.secret_type'::regtype",
          "'hidden_sentinel.nothere_type'::regtype", "'hidden_sentinel'::regnamespace", "'nothere'::regnamespace"
        ]
        errors = literals.map do |literal|
          check("SELECT #{literal} FROM orders", path)
        rescue described_class::Error => e
          [e.message, Quaack::Enclave::ErrorFilter.to_egress(e, step: "llm-rewrites")]
        end

        expect(errors.uniq.size).to eq(1)
        message, line = errors.first
        expect(message).to start_with("unsupported_reg_literal: ")
        expect(line).to include('"rule":"unsupported_reg_literal"')
        [message, line].each { expect(it).not_to include("sentinel") }
      end

      it "accepts the original's own regclass literal, as its $n" do
        expect(check("SELECT $1::regclass FROM orders", path).sql).to eq("SELECT $1::regclass FROM public.orders")
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
