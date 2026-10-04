# frozen_string_literal: true

require "quaack/enclave/schema_payload"

# The schema the llm-index-ideas and llm-rewrites payloads send (DESIGN.md's llm-index-ideas): the subset's
# DDL for the query's own tables only, without pg_dump's noise.
RSpec.describe Quaack::Enclave::SchemaPayload do
  # pg_dump --schema-only --no-owner --no-privileges output, as schema-dump stores it
  # for a query on orders, whose FK parent is customers.
  let(:dump) do
    <<~SQL
      --
      -- PostgreSQL database dump
      --

      \\restrict AbC123

      -- Dumped from database version 18.0

      SET statement_timeout = 0;
      SET client_encoding = 'UTF8';
      SELECT pg_catalog.set_config('search_path', '', false);
      SET default_table_access_method = heap;

      --
      -- Name: order_status; Type: TYPE; Schema: public; Owner: -
      --

      CREATE TYPE public.order_status AS ENUM (
          'open',
          'held'
      );

      --
      -- Name: money_amount; Type: DOMAIN; Schema: public; Owner: -
      --

      CREATE DOMAIN public.money_amount AS numeric(12,2)
      \tCONSTRAINT money_amount_check CHECK ((VALUE >= (0)::numeric));

      --
      -- Name: customers; Type: TABLE; Schema: public; Owner: -
      --

      CREATE TABLE public.customers (
          id bigint NOT NULL,
          tier text
      );

      COMMENT ON TABLE public.customers IS 'People who buy';

      --
      -- Name: orders; Type: TABLE; Schema: public; Owner: -
      --

      CREATE TABLE public.orders (
          id bigint NOT NULL,
          customer_id bigint NOT NULL,
          status public.order_status NOT NULL,
          total public.money_amount
      );

      COMMENT ON COLUMN public.orders.total IS 'In dollars';

      --
      -- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
      --

      CREATE SEQUENCE public.orders_id_seq
          START WITH 1
          INCREMENT BY 1
          NO MINVALUE
          NO MAXVALUE
          CACHE 1;

      ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;

      ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);

      ALTER TABLE ONLY public.customers
          ADD CONSTRAINT customers_pkey PRIMARY KEY (id);

      ALTER TABLE ONLY public.orders
          ADD CONSTRAINT orders_pkey PRIMARY KEY (id);

      CREATE INDEX customers_tier_idx ON public.customers USING btree (tier);

      CREATE INDEX orders_status_idx ON public.orders USING btree (status);

      ALTER TABLE ONLY public.orders
          ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);

      ALTER TABLE public.orders OWNER TO app;

      GRANT SELECT ON TABLE public.orders TO reporting;

      SELECT pg_catalog.setval('public.orders_id_seq', 1, false);

      --
      -- PostgreSQL database dump complete
      --

      \\unrestrict AbC123
    SQL
  end

  it "keeps the types, enums, domains, and the query's own tables with their constraints and indexes" do
    trimmed = described_class.ddl(dump, [%w[public orders]])

    expect(trimmed).to eq(<<~SQL)
      CREATE TYPE public.order_status AS ENUM (
          'open',
          'held'
      );

      CREATE DOMAIN public.money_amount AS numeric(12,2)
      \tCONSTRAINT money_amount_check CHECK ((VALUE >= (0)::numeric));

      CREATE TABLE public.orders (
          id bigint NOT NULL,
          customer_id bigint NOT NULL,
          status public.order_status NOT NULL,
          total public.money_amount
      );

      ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);

      ALTER TABLE ONLY public.orders
          ADD CONSTRAINT orders_pkey PRIMARY KEY (id);

      CREATE INDEX orders_status_idx ON public.orders USING btree (status);

      ALTER TABLE ONLY public.orders
          ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);
    SQL
  end

  it "keeps a statement it can't classify" do
    ddl = "CREATE FUNCTION public.f() RETURNS integer LANGUAGE sql AS 'SELECT 1';\n" \
          "CREATE TABLE public.orders (id integer);\n"

    expect(described_class.ddl(ddl, [%w[public orders]])).to eq(ddl.sub(";\n", ";\n\n"))
  end

  it "trims a schema_subset entry's tables to the query's own" do
    subset = { "tables" => [%w[public orders], %w[public customers]], "ddl" => dump }

    trimmed = described_class.subset(subset, [{ "schema" => "public", "name" => "orders" }])

    expect(trimmed["tables"]).to eq([%w[public orders]])
    expect(trimmed["ddl"]).to eq(described_class.ddl(dump, [%w[public orders]]))
  end
end
