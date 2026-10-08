# frozen_string_literal: true

require "quaack/enclave/relations"

# Task 20260926-56: DESIGN.md's qualify names the schema of functions,
# operators, types, collations, and the names in regclass and regtype
# literals, where that's exact. It goes through Relations.check, the way the
# qualify step does, against real Postgres, since resolving names reads the
# catalog.
RSpec.describe "qualifying names other than relations" do
  let(:conn) { test_database.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE TABLE sales.items (id int, order_id bigint, qty int);
      CREATE FUNCTION public.shout(text) RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT upper($1)';
      CREATE FUNCTION public.twice(int) RETURNS int IMMUTABLE LANGUAGE sql AS 'SELECT $1 * 2';
      CREATE FUNCTION sales.twice(int) RETURNS int IMMUTABLE LANGUAGE sql AS 'SELECT $1 * 3';
      CREATE FUNCTION public.lower(int) RETURNS int IMMUTABLE LANGUAGE sql AS 'SELECT $1';
      CREATE FUNCTION public.near(int, int) RETURNS boolean IMMUTABLE LANGUAGE sql AS 'SELECT abs($1 - $2) < 2';
      CREATE OPERATOR public.=~= (FUNCTION = public.near, LEFTARG = int, RIGHTARG = int);
      CREATE FUNCTION public.same(text, int) RETURNS boolean IMMUTABLE LANGUAGE sql AS 'SELECT $1 = $2::text';
      CREATE OPERATOR public.= (FUNCTION = public.same, LEFTARG = text, RIGHTARG = int);
      CREATE TYPE public.mood AS ENUM ('ok', 'sad');
      CREATE TYPE sales.mood AS ENUM ('ok', 'sad');
      CREATE COLLATION public.plain FROM "C";
    SQL
  end

  def qualified(sql, settings = nil) = Quaack::Enclave::Relations.check(sql, settings, conn).sql

  def rejected(rule)
    raise_error(Quaack::Enclave::Relations::Error) do |error|
      expect([error.rule, error.cause]).to eq([rule, nil])
    end
  end

  describe "a function" do
    it "names the one schema on the path, other than pg_catalog, that has the name" do
      expect(qualified("SELECT shout(status) FROM orders"))
        .to eq("SELECT public.shout(status) FROM public.orders")
    end

    it "names whichever schema that is, through the plan's search_path" do
      expect(qualified("SELECT twice(qty) FROM items", { "search_path" => "sales" }))
        .to eq("SELECT sales.twice(qty) FROM sales.items")
    end

    it "stays bare when only pg_catalog has the name" do
      expect(qualified("SELECT count(*), max(status), date_trunc('day', created_at) FROM orders"))
        .to eq("SELECT count(*), max(status), date_trunc('day', created_at) FROM public.orders")
    end

    it "stays bare when pg_catalog and another schema both have the name" do
      expect(qualified("SELECT lower(status) FROM orders")).to eq("SELECT lower(status) FROM public.orders")
    end

    it "stays bare when two schemas on the path other than pg_catalog have the name" do
      expect(qualified("SELECT twice(total_cents) FROM orders", { "search_path" => "sales, public" }))
        .to eq("SELECT twice(total_cents) FROM public.orders")
    end

    it "keeps a schema the query names" do
      expect(qualified("SELECT sales.twice(total_cents) FROM orders"))
        .to eq("SELECT sales.twice(total_cents) FROM public.orders")
    end
  end

  describe "an operator" do
    it "names the one schema that has it, written as OPERATOR()" do
      expect(qualified("SELECT id FROM orders WHERE total_cents =~= 3"))
        .to eq("SELECT id FROM public.orders WHERE total_cents OPERATOR(public.=~=) 3")
    end

    it "stays bare when pg_catalog has one of the name too, as for an extension's =" do
      expect(qualified("SELECT id FROM orders WHERE status = 'open' AND total_cents > 3"))
        .to eq("SELECT id FROM public.orders WHERE status = 'open' AND total_cents > 3")
    end
  end

  describe "a type" do
    it "names the first schema on the path that has it" do
      expect(qualified("SELECT 'ok'::mood FROM orders")).to eq("SELECT 'ok'::public.mood FROM public.orders")
      expect(qualified("SELECT CAST('ok' AS mood) FROM orders", { "search_path" => "sales, public" }))
        .to eq("SELECT 'ok'::sales.mood FROM public.orders")
    end

    it "stays bare when it's pg_catalog's" do
      expect(qualified("SELECT status::text, created_at::date, total_cents::int FROM orders"))
        .to eq("SELECT status::text, created_at::date, total_cents::int FROM public.orders")
    end
  end

  describe "a collation" do
    it "names the first schema on the path that has it, and leaves pg_catalog's bare" do
      expect(qualified("SELECT id FROM orders ORDER BY status COLLATE plain, status COLLATE \"C\""))
        .to eq("SELECT id FROM public.orders ORDER BY status COLLATE public.plain, status COLLATE \"C\"")
    end
  end

  describe "a regclass literal" do
    it "names the schema of the relation, as relations are named" do
      expect(qualified("SELECT 'orders'::regclass, 'sales.items'::regclass FROM orders"))
        .to eq("SELECT 'public.orders'::regclass, 'sales.items'::regclass FROM public.orders")
      expect(qualified("SELECT regclass 'items' FROM orders", { "search_path" => "sales, public" }))
        .to eq("SELECT 'sales.items'::regclass FROM public.orders")
    end

    it "quotes a name that needs it" do
      conn.exec('CREATE TABLE public."Odd Name" (id int)')
      expect(qualified(%(SELECT '"Odd Name"'::regclass FROM orders)))
        .to eq(%(SELECT 'public."Odd Name"'::regclass FROM public.orders))
    end

    it "is refused when no schema on the path has the name" do
      expect { qualified("SELECT 'nowhere'::regclass FROM orders") }.to rejected("unknown_relation")
    end

    it "is refused when it's an oid" do
      expect { qualified("SELECT '1259'::regclass FROM orders") }.to rejected("unsupported_reg_literal")
    end

    it "is refused when it's an array" do
      expect { qualified("SELECT '{orders}'::regclass[] FROM orders") }.to rejected("unsupported_reg_literal")
    end
  end

  describe "a regtype literal" do
    it "names the type's schema, unless it's pg_catalog" do
      expect(qualified("SELECT 'mood'::regtype, 'mood[]'::regtype, 'int4'::regtype FROM orders"))
        .to eq("SELECT 'public.mood'::regtype, 'public.mood[]'::regtype, 'int4'::regtype FROM public.orders")
    end

    it "is refused when it isn't one type name" do
      expect { qualified("SELECT 'mood; SELECT 1'::regtype FROM orders") }.to rejected("unsupported_reg_literal")
    end
  end

  it "refuses a regproc, regprocedure, regoper, or regoperator literal" do
    ["'lower'::regproc", "'lower(text)'::regprocedure", "'+'::regoper", "'+(int4,int4)'::regoperator",
     "'lower'::pg_catalog.regproc"].each do |literal|
      expect { qualified("SELECT #{literal} FROM orders") }.to rejected("unsupported_reg_literal"), literal
    end
  end

  it "leaves a cast of a column to regproc alone, since it names no function" do
    expect(qualified("SELECT total_cents::oid::regproc FROM orders"))
      .to eq("SELECT total_cents::oid::regproc FROM public.orders")
  end
end
