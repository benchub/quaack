# frozen_string_literal: true

require "quaack/enclave/result_comparison/tiebreaker"
require_relative "support/catalog_shadow"

# Task 20261007-9: the tiebreaker's catalog reads, on the racetrack and the
# arena, when public's comparisons, ahead of pg_catalog's on the
# search_path, say no (see CatalogShadow). They still find what's there.
RSpec.describe Quaack::Enclave::ResultComparison::Tiebreaker do
  let(:conn) { test_database.connection }
  # What the reads need of a transaction: query(sql).rows.
  let(:transaction) do
    Struct.new(:conn) do
      def query(sql) = Struct.new(:rows).new(conn.exec(sql).values)
    end.new(conn)
  end

  def oid(type)
    Integer(conn.exec("SELECT #{conn.escape_literal(type)}::pg_catalog.regtype::pg_catalog.oid").getvalue(0, 0))
  end

  before do
    conn.exec("CREATE TYPE public.mood AS ENUM ('sad', 'happy')")
    conn.exec("CREATE TYPE public.pair AS (a pg_catalog.int4, m public.mood)")
    conn.exec("CREATE COLLATION public.loose (provider = icu, locale = 'und-u-ks-level2', deterministic = false)")
    conn.exec("SET search_path = public, pg_catalog")
    CatalogShadow.plant(conn, :operators)
  end

  it "finds the enums, their arrays, and the composites of faithful fields that ORDER BY can sort" do
    types = [oid("public.mood"), oid("public.mood[]"), oid("public.pair"), oid("pg_catalog.json")]

    expect(described_class.catalog_orderable(transaction, types).sort).to eq(types.first(3).sort)
  end

  it "finds a nondeterministic collation that a column uses, or that a query names" do
    odd = %(it's "odd" \\x)
    conn.exec("CREATE COLLATION public.#{conn.quote_ident(odd)} " \
              "(provider = icu, locale = 'und-u-ks-level2', deterministic = false)")
    named = [["loose"], [odd], ["it's"], ["x"]].map { described_class.nondeterministic_collation?(transaction, it) }
    expect(named).to eq([true, true, false, false])
    conn.exec("DROP COLLATION public.#{conn.quote_ident(odd)}")
    named = described_class.nondeterministic_collation?(transaction, ["loose"])
    unused = described_class.nondeterministic_collation?(transaction, [])
    conn.exec("CREATE TABLE public.notes (body pg_catalog.text COLLATE public.loose)")

    expect([named, unused, described_class.nondeterministic_collation?(transaction, [])]).to eq([true, false, true])
  end
end
