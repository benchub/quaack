# frozen_string_literal: true

require "quaack/enclave/assumption_check"
require_relative "support/catalog_shadow"
require_relative "support/production_server"

# DESIGN.md's assumption-check: each stated assumption, checked against pg_constraint and
# pg_index on a real server, with NOT VALID constraints treated as absent.
RSpec.describe Quaack::Enclave::AssumptionCheck do
  let!(:production) { ProductionServer.create(ProductionServer.sentinels) }
  let(:conn) { production.connect }

  after do
    conn.close
    production.drop
  end

  before do
    conn.exec(<<~SQL)
      CREATE TABLE public.customers (id int PRIMARY KEY, email text, region text);
      CREATE UNIQUE INDEX customers_email_live ON public.customers (email) WHERE region IS NOT NULL;
      CREATE TABLE public.orders (id int PRIMARY KEY, customer_id int REFERENCES public.customers (id),
                                  seller_id int, note text, total int CHECK (total >= 0), qty int);
      ALTER TABLE public.orders ADD CONSTRAINT qty_positive CHECK (qty > 0) NOT VALID;
      ALTER TABLE public.orders ADD CONSTRAINT seller_fk FOREIGN KEY (seller_id) REFERENCES public.customers (id) NOT VALID;
      ALTER TABLE public.orders ADD CONSTRAINT note_nn NOT NULL note NOT VALID;
      CREATE TABLE public.items (id int PRIMARY KEY, sku text, code text NOT NULL, tag text, ref int NOT NULL,
                                 price numeric CHECK (price > 0), lot int,
                                 state text CHECK (state IN ('new', 'paid')), kind text CHECK (kind NOT IN ('x', 'y')), CONSTRAINT lot_pos CHECK (lot > 0) NO INHERIT);
      CREATE UNIQUE INDEX items_sku ON public.items (sku);
      CREATE UNIQUE INDEX items_code ON public.items (code);
      CREATE UNIQUE INDEX items_tag ON public.items (tag) NULLS NOT DISTINCT;
      ALTER TABLE public.items ADD CONSTRAINT items_ref UNIQUE (ref) DEFERRABLE;
      ALTER TABLE public.items ADD grade text CHECK (grade IN ('a')), ADD flag text CHECK (flag NOT IN ('z'));
    SQL
  end

  def met?(assumption) = described_class.met?(assumption, conn)
  def not_null(column) = { "kind" => "not_null", "table" => "public.orders", "column" => column }
  def unique(table, *columns) = { "kind" => "unique", "table" => table, "columns" => columns }
  def check(expression) = { "kind" => "check", "table" => "public.orders", "expression" => expression }

  def fk(column, references = ["public.customers", "id"])
    { "kind" => "foreign_key", "table" => "public.orders", "columns" => [column],
      "references_table" => references[0], "references_columns" => [references[1]] }
  end

  it "meets NOT NULL only for a validated not-null or primary key constraint" do
    expect([met?(not_null("id")), met?(not_null("total")), met?(not_null("note"))]).to eq([true, false, false])
  end

  it "meets a unique column set covered by a valid, full, plain unique index" do
    expect([met?(unique("public.orders", "id")), met?(unique("public.orders", "id", "note")),
            met?(unique("public.orders", "note")), met?(unique("public.customers", "email"))])
      .to eq([true, true, false, false])
  end

  it "meets a foreign key only when a validated one matches its columns and referenced table" do
    expect([met?(fk("customer_id")), met?(fk("seller_id")), met?(fk("customer_id", ["public.orders", "id"]))])
      .to eq([true, false, false])
  end

  it "meets a CHECK only for a validated one whose normalized expression is identical" do
    expect([met?(check("total >= 0")), met?(check("(total >= 0)")), met?(check("total > 0")),
            met?(check("qty > 0")), met?(check("total >= 0; SELECT 1"))])
      .to eq([true, true, false, false, false])
  end

  it "meets a unique set only when its index keys are NOT NULL or NULLS NOT DISTINCT, and not deferrable" do
    expect([met?(unique("public.items", "sku")), met?(unique("public.items", "code")),
            met?(unique("public.items", "tag")), met?(unique("public.items", "ref"))])
      .to eq([false, true, true, false])
  end

  it "meets a CHECK despite the casts Postgres adds, and one marked NO INHERIT" do
    items = ->(expression) { check(expression).merge("table" => "public.items") }
    expect([met?(items.call("price > 0")), met?(items.call("price > 1")), met?(items.call("lot > 0"))])
      .to eq([true, false, true])
  end

  it "meets a CHECK stated as an IN list, which Postgres stores as = ANY (ARRAY[...])" do
    items = ->(expression) { check(expression).merge("table" => "public.items") }
    expect([met?(items.call("state IN ('new', 'paid')")), met?(items.call("state IN ('new')")),
            met?(items.call("kind NOT IN ('x', 'y')")), met?(items.call("kind IN ('x', 'y')"))])
      .to eq([true, false, true, false])
  end

  it "meets a one-element IN list CHECK, which Postgres stores as plain = or <>" do
    items = ->(expression) { check(expression).merge("table" => "public.items") }
    expect([met?(items.call("grade IN ('a')")), met?(items.call("flag NOT IN ('z')")),
            met?(items.call("grade = 'a'")), met?(items.call("grade IN ('b')"))])
      .to eq([true, true, true, false])
  end

  # Task 20261007-9: public's comparisons, ahead of pg_catalog's on the
  # search_path, say no or say yes (see CatalogShadow). The catalog reads
  # still find what's there, and only that.
  describe "when public's comparison operators shadow pg_catalog's" do
    before { conn.exec("SET search_path = public, pg_catalog") }

    it "still meets what's met, when they say no" do
      CatalogShadow.plant(conn, :operators)

      expect([met?(not_null("id")), met?(unique("public.orders", "id")), met?(unique("public.items", "code")),
              met?(fk("customer_id")), met?(check("total >= 0"))]).to eq([true, true, true, true, true])
    end

    it "still doesn't meet what isn't, when they say yes" do
      CatalogShadow.plant(conn, :yes_operators)

      expect([met?(not_null("total")), met?(unique("public.orders", "note")), met?(unique("public.items", "sku")),
              met?(fk("customer_id", ["public.orders", "id"])), met?(check("qty > 0"))])
        .to eq([false, false, false, false, false])
    end
  end

  it "doesn't meet an assumption about a table that doesn't exist" do
    expect(met?(not_null("id").merge("table" => "public.nowhere"))).to be(false)
  end

  # Canvas's shape: a submission copies its assignment's course into
  # course_id, which only Rails keeps equal to context_id when
  # context_type is 'Course'. The schema can't say so; the data can.
  describe "denormalized_equal, checked against the data" do
    before do
      conn.exec(<<~SQL)
        CREATE TABLE public.assignments (id bigint PRIMARY KEY, context_type varchar(255), context_id bigint);
        CREATE TABLE public.submissions (id bigint PRIMARY KEY, assignment_id bigint, course_id bigint);
        INSERT INTO public.assignments VALUES (1, 'Course', 10), (2, 'Course', 20), (3, 'Group', 30);
        INSERT INTO public.submissions VALUES (1, 1, 10), (2, 1, 10), (3, 2, 20), (4, 3, 99), (5, NULL, 77);
      SQL
    end

    let(:assumption) do
      { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => "course_id",
        "join_column" => "assignment_id", "references_table" => "public.assignments", "references_column" => "id",
        "type_column" => "context_type", "type_value" => "Course", "id_column" => "context_id" }
    end

    it "is met when every joined row of that type has the copy equal to the id" do
      expect(met?(assumption)).to be(true)
    end

    it "isn't met when one joined row of that type has a different copy, or a NULL one" do
      conn.exec("UPDATE public.submissions SET course_id = 21 WHERE id = 3")
      differs = met?(assumption)
      conn.exec("UPDATE public.submissions SET course_id = NULL WHERE id = 3")

      expect([differs, met?(assumption)]).to eq([false, false])
    end

    # Task 20261007-9: public's comparisons, ahead of pg_catalog's on the
    # search_path, say no (see CatalogShadow), so an unqualified join would
    # find no rows, and nothing to contradict the assumption.
    it "still checks the data when public's comparison operators shadow pg_catalog's" do
      conn.exec("SET search_path = public, pg_catalog")
      CatalogShadow.plant(conn, :operators)
      met = met?(assumption)
      conn.exec("UPDATE public.submissions SET course_id = 21 WHERE id OPERATOR(pg_catalog.=) 3")
      differs = met?(assumption)
      conn.exec("UPDATE public.submissions SET course_id = NULL WHERE id OPERATOR(pg_catalog.=) 3")

      expect([met, differs, met?(assumption)]).to eq([true, false, false])
    end

    # Task 20261007-9: a column's = is its type's own, as the application's
    # query has it. citext's is case-insensitive, and its implicit cast to
    # text mustn't turn the comparisons into text's, which would find no
    # joined row of the type and call a contradicted assumption met.
    describe "on columns whose type has its own =" do
      before do
        conn.exec(<<~SQL)
          CREATE EXTENSION citext SCHEMA public;
          CREATE TYPE public.kind AS ENUM ('Foo', 'Bar');
          CREATE TABLE public.parents (ref public.citext, kind public.citext, ident public.citext, mood public.kind);
          CREATE TABLE public.children (j public.citext, col public.citext);
          INSERT INTO public.parents VALUES ('a', 'Foo', 'X', 'Foo');
          INSERT INTO public.children VALUES ('A', 'y');
        SQL
      end

      let(:assumption) do
        { "kind" => "denormalized_equal", "table" => "public.children", "column" => "col",
          "join_column" => "j", "references_table" => "public.parents", "references_column" => "ref",
          "type_column" => "kind", "type_value" => "foo", "id_column" => "ident" }
      end

      it "compares them with that =, so a row it calls equal still contradicts the assumption" do
        contradicted = met?(assumption)
        conn.exec("UPDATE public.children SET col = 'x'")

        expect([contradicted, met?(assumption)]).to eq([false, true])
      end

      it "compares an enum type column with the enum's =" do
        moody = assumption.merge("type_column" => "mood", "type_value" => "Foo")
        contradicted = met?(moody)
        conn.exec("UPDATE public.children SET col = 'x'")

        expect([contradicted, met?(moody)]).to eq([false, true])
      end
    end

    it "checks only rows of the stated type" do
      expect(met?(assumption.merge("type_value" => "Group"))).to be(false)
    end

    it "runs under a 300000 ms statement timeout, and a timeout is unmet" do
      expect(described_class::DenormalizedEqual::TIMEOUT_MS).to eq(300_000)
      stub_const("#{described_class}::DenormalizedEqual::TIMEOUT_MS", 200)
      locker = production.connect
      locker.exec("BEGIN")
      locker.exec("LOCK TABLE public.submissions IN ACCESS EXCLUSIVE MODE")

      expect(met?(assumption)).to be(false)
      locker.exec("ROLLBACK")
      expect(met?(assumption)).to be(true)
    ensure
      locker&.close
    end

    it "is unmet when the check fails, and leaves the connection usable" do
      expect([met?(assumption.merge("type_column" => "context_id")),
              met?(assumption.merge("table" => "public.nowhere"))]).to eq([false, false])
      expect([conn.transaction_status, met?(assumption)]).to eq([PG::PQTRANS_IDLE, true])
    end
  end
end
