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

  # Task 20261002-4: a rule reads unique as "no two rows are equal in these
  # columns", by the column's own =. An index that compares more finely
  # than that lets two rows the column calls equal both in: under a
  # case-blind collation, b's 'Ann' and 'ann'. A deterministic collation's
  # = is byte equality, so two of those agree, as on d. A non-default
  # operator class is refused even where it agrees, as text_pattern_ops
  # does on e, since one such as record_image_ops compares more finely.
  it "meets a unique set only when its index compares as the column does" do
    conn.exec(<<~SQL)
      CREATE COLLATION public.blind (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
      CREATE TABLE public.people (a text COLLATE public.blind NOT NULL, b text COLLATE public.blind NOT NULL,
                                  d text NOT NULL, e text NOT NULL);
      CREATE UNIQUE INDEX ON public.people (a);
      CREATE UNIQUE INDEX ON public.people (b COLLATE "C");
      CREATE UNIQUE INDEX ON public.people (d COLLATE "C");
      CREATE UNIQUE INDEX ON public.people (e text_pattern_ops);
      INSERT INTO public.people VALUES ('Ann', 'Ann', 'Ann', 'Ann'), ('x', 'ann', 'x', 'x');
    SQL

    expect(%w[a b d e].map { met?(unique("public.people", it)) }).to eq([true, false, true, false])
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

    # Task 20261007-32: IS NOT DISTINCT FROM, written out, calls a NULL
    # copy of a NULL id equal.
    it "is met when a joined row of that type has a NULL copy of a NULL id" do
      conn.exec("INSERT INTO public.assignments VALUES (4, 'Course', NULL)")
      conn.exec("INSERT INTO public.submissions VALUES (6, 4, NULL)")

      expect(met?(assumption)).to be(true)
    end

    # Task 20261007-32: a domain, even one over another domain, is compared
    # by its base type's =.
    it "checks the data when the columns are domains" do
      conn.exec(<<~SQL)
        CREATE DOMAIN public.ident AS bigint;
        CREATE DOMAIN public.course_ref AS public.ident;
        CREATE DOMAIN public.label AS varchar(255);
        ALTER TABLE public.submissions ALTER course_id TYPE public.course_ref, ALTER assignment_id TYPE public.ident;
        ALTER TABLE public.assignments ALTER context_id TYPE public.course_ref, ALTER context_type TYPE public.label;
      SQL
      met = met?(assumption)
      conn.exec("UPDATE public.submissions SET course_id = 21 WHERE id = 3")

      expect([met, met?(assumption)]).to eq([true, false])
    end

    # Task 20261007-32: the type value is cast to the type column's type by
    # its schema-qualified name, so a type planted ahead of it on the
    # search_path, here a text domain that refuses every value (see
    # CatalogShadow), can't make the check fail.
    it "casts the type value to the type column's own type" do
      conn.exec("ALTER TABLE public.assignments ALTER context_type TYPE text")
      conn.exec("SET search_path = public, pg_catalog")
      CatalogShadow.plant(conn, :operators, :text)
      met = met?(assumption)
      conn.exec("UPDATE public.submissions SET course_id = 21 WHERE id OPERATOR(pg_catalog.=) 3")

      expect([met, met?(assumption)]).to eq([true, false])
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

    # Task 20261007-39: an array, range, multirange, or composite type's
    # default btree opclass takes a polymorphic type (anyarray and the
    # like), so its = is accepted only when both columns have exactly that
    # type.
    describe "on columns of the same array, range, multirange, or composite type" do
      before { %w[pair other_pair].each { conn.exec("CREATE TYPE public.#{it} AS (n int, s text)") } }

      def retype(table, column, type, using)
        conn.exec("ALTER TABLE public.#{table} ALTER #{column} TYPE #{type} USING #{value(using, column)}")
      end

      # using, with value in place of {}.
      def value(using, value) = using.gsub("{}", value.to_s)

      {
        "int4[]" => "ARRAY[{}::int4]", "text[]" => "ARRAY[{}::text]",
        "int4range" => "int4range({}::int4, {}::int4 + 1)",
        "int4multirange" => "int4multirange(int4range({}::int4, {}::int4 + 1))",
        "public.pair" => "ROW({}::int4, 'z')::public.pair"
      }.each do |type, using|
        it "checks the data when both are #{type}" do
          retype("submissions", "course_id", type, using)
          retype("assignments", "context_id", type, using)
          met = met?(assumption)
          conn.exec("UPDATE public.submissions SET course_id = #{value(using, 21)} WHERE id = 3")

          expect([met, met?(assumption)]).to eq([true, false])
        end
      end

      {
        "int4[] and int8[]" => [%w[int4[] ARRAY[{}::int4]], %w[int8[] ARRAY[{}]]],
        "int4range and int8range" => [["int4range", "int4range({}::int4, {}::int4 + 1)"],
                                      ["int8range", "int8range({}, {} + 1)"]],
        "two composite types" => [["public.pair", "ROW({}::int4, 'z')::public.pair"],
                                  ["public.other_pair", "ROW({}::int4, 'z')::public.other_pair"]]
      }.each do |name, ((child_type, child_using), (parent_type, parent_using))|
        it "still refuses #{name}" do
          retype("submissions", "course_id", child_type, child_using)
          retype("assignments", "context_id", parent_type, parent_using)

          types = [%w[public.submissions course_id], %w[public.assignments context_id]]
                  .map { described_class::Equality.column_type(conn, *it) }

          expect([met?(assumption), described_class::Equality.operator(conn, *types)]).to eq([false, nil])
        end
      end

      # Task 20261007-45: a bare = picks an exact-type = on the type over
      # the polymorphic one, so Equality can't say which the application's
      # query gets, and refuses.
      { "public.pair" => "ROW({}::int4, 'z')::public.pair", "int4[]" => "ARRAY[{}::int4]",
        "public.mood" => "'Foo'::public.mood" }.each do |type, using|
        it "refuses #{type} when an = of its own is planted outside its btree family" do
          conn.exec("CREATE TYPE public.mood AS ENUM ('Foo', 'Bar')")
          retype("submissions", "course_id", type, using)
          retype("assignments", "context_id", type, using)
          oid = described_class::Equality.column_type(conn, "public.submissions", "course_id")
          before = [met?(assumption), described_class::Equality.operator(conn, oid, oid)]
          conn.exec(<<~SQL)
            CREATE FUNCTION public.same(#{type}, #{type}) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true';
            CREATE OPERATOR public.= (LEFTARG = #{type}, RIGHTARG = #{type}, FUNCTION = public.same);
          SQL

          expect([*before, met?(assumption), described_class::Equality.operator(conn, oid, oid)])
            .to eq([true, "OPERATOR(pg_catalog.=)", false, nil])
        end
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

    # Task 20261007-32: the = must be one operator. Postgres keeps one
    # default btree opclass per type, but the catalog doesn't enforce it,
    # so two are planted here, and two types a type coerces to.
    describe "when the catalog gives more than one =" do
      def oid(type) = Integer(conn.exec("SELECT '#{type}'::pg_catalog.regtype::pg_catalog.oid").getvalue(0, 0))
      def equality(type) = described_class::Equality.operator(conn, oid(type), oid(type))

      # Postgres itself then fails to plan the check, so only the = says
      # what Equality does.
      it "refuses two default btree opclasses for the type" do
        before = equality("bigint")
        conn.exec(<<~SQL)
          CREATE FUNCTION public.same(bigint, bigint) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true';
          CREATE OPERATOR public.= (LEFTARG = bigint, RIGHTARG = bigint, FUNCTION = public.same);
          CREATE OPERATOR CLASS public.loose_ops FOR TYPE bigint USING btree
            AS OPERATOR 3 public.= (bigint, bigint), FUNCTION 1 pg_catalog.btint8cmp(bigint, bigint);
          UPDATE pg_catalog.pg_opclass SET opcdefault = true WHERE opcname = 'loose_ops';
        SQL

        expect([before, equality("bigint")]).to eq(["OPERATOR(pg_catalog.=)", nil])
      end

      it "refuses a type with no opclass of its own that coerces to two preferred types" do
        before = [equality("varchar"), met?(assumption)]
        conn.exec("CREATE CAST (varchar AS inet) WITHOUT FUNCTION AS IMPLICIT")

        expect([*before, equality("varchar"), met?(assumption)]).to eq(["OPERATOR(pg_catalog.=)", true, nil, false])
      end
    end
  end
end
