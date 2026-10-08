# frozen_string_literal: true

require "quaack/enclave/steps/index_search"
require "quaack/enclave/steps/rewrite_check"
require_relative "support/catalog_shadow"

# Task 20261007-9: the racetrack reads that name a type by its oid, when
# public's functions and text, ahead of pg_catalog's on the search_path,
# give wrong answers (see CatalogShadow). Each still names the type.
RSpec.describe "a racetrack read of a type's name" do
  let(:conn) { test_database.connection }

  before do
    conn.exec("SET search_path = public, pg_catalog")
    conn.exec("CREATE FUNCTION public.format_type(pg_catalog.oid, pg_catalog.int4) RETURNS pg_catalog.text " \
              "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.text $$")
    conn.exec("CREATE FUNCTION public.unnest(pg_catalog.oid[]) RETURNS SETOF pg_catalog.oid " \
              "LANGUAGE sql AS $$ SELECT 25::pg_catalog.oid $$")
    CatalogShadow.plant(conn, :text)
  end

  it "names each parameter's type in an index search" do
    types = Quaack::Enclave::Steps::IndexSearch.parameter_types(conn, "SELECT $1 + 1, $2", %w[integer bigint])

    expect(types).to eq("$1" => "integer", "$2" => "bigint")
  end

  it "names each result type in a rewrite check" do
    expect(Quaack::Enclave::StructuralDiscard.type_names(conn, %w[23 20])).to eq(%w[integer bigint])
  end
end
