# frozen_string_literal: true

require "quaack/enclave/assumption_check"
require_relative "support/production_server"

# README 6b: each stated assumption, checked against pg_constraint and
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

  it "doesn't meet an assumption about a table that doesn't exist" do
    expect(met?(not_null("id").merge("table" => "public.nowhere"))).to be(false)
  end
end
