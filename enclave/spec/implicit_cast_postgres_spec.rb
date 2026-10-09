# frozen_string_literal: true

require "quaack/enclave/index_candidate"
require "quaack/enclave/dedupe"

# Task 20261009-20: pg_get_indexdef prints the implicit casts Postgres added
# to a varchar column's predicate. A candidate written without them is still
# covered, but a cast that changes meaning is never dropped. Real server.
RSpec.describe "implicit casts in an existing index's predicate, against a real server" do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "cast_t") }
  let(:types) { { "ctx" => "varchar", "note" => "text", "n" => "int4", "a" => "int4" } }

  def existing(where, types: self.types)
    conn.exec("DROP TABLE IF EXISTS cast_t")
    conn.exec("CREATE TABLE cast_t (a int, n int, ctx varchar(20), note text)")
    conn.exec("CREATE INDEX cast_idx ON cast_t (a) WHERE #{where}")
    ddl = conn.exec("SELECT pg_get_indexdef('cast_idx'::regclass)").getvalue(0, 0)
    Quaack::Enclave::IndexCandidate.from_indexdef(ddl, types:)
  end

  def candidate(predicate)
    Quaack::Enclave::IndexCandidate.new(table: t, key: ["a"], sources: [:parse], predicate:)
  end

  def covers?(index, predicate) = Quaack::Enclave::Dedupe.covers?(index, candidate(predicate))

  it "prints the casts, so the test means something" do
    existing("ctx = 'Course'")
    expect(conn.exec("SELECT pg_get_indexdef('cast_idx'::regclass)").getvalue(0, 0)).to include("(ctx)::text")
  end

  it "covers a candidate without the casts on a varchar column" do
    index = existing("ctx = 'Course' AND note = 'x'")
    expect(covers?(index, "ctx = 'Course' AND note = 'x'")).to be(true)
    expect(covers?(index, "note = 'x' AND ctx = 'Course'")).to be(true)
    expect(covers?(index, "ctx = 'Other' AND note = 'x'")).to be(false)
  end

  it "covers an IN list and a not-equal on a varchar column" do
    index = existing("ctx IN ('a', 'b') AND ctx <> 'c'")
    expect(covers?(index, "ctx IN ('a', 'b') AND ctx <> 'c'")).to be(true)
    expect(covers?(index, "ctx IN ('a', 'z') AND ctx <> 'c'")).to be(false)
  end

  it "covers a NOT IN list on a varchar column" do
    index = existing("ctx NOT IN ('a', 'b')")
    expect(covers?(index, "ctx NOT IN ('a', 'b')")).to be(true)
    expect(covers?(index, "ctx IN ('a', 'b')")).to be(false)
  end

  it "keeps the cast when the column's type isn't known" do
    index = existing("ctx = 'Course'", types: {})
    expect(covers?(index, "ctx = 'Course'")).to be(false)
  end

  it "keeps a cast of an int column to text, which changes meaning" do
    index = existing("n::text = '5'")
    expect(covers?(index, "n = '5'")).to be(false)
    expect(covers?(index, "n = 5")).to be(false)
    expect(index.predicate).to include("::text")
  end

  it "keeps a cast to another type or a collation" do
    expect(existing("ctx::varchar(3) = 'abc'").predicate).to include("varchar")
    index = existing("ctx COLLATE \"C\" = 'abc'")
    expect(covers?(index, "ctx = 'abc'")).to be(false)
  end

  it "keeps the cast when the constant's cast isn't plain text" do
    index = existing("ctx::text = 'abc'::name")
    expect(index.predicate).to include("::name")
    expect(covers?(index, "ctx = 'abc'")).to be(false)
  end

  it "doesn't rewrite an empty array into an empty IN list" do
    ddl = "CREATE INDEX cast_idx ON public.cast_t USING btree (a) WHERE ((ctx)::text = ANY (ARRAY[]::text[]))"
    index = Quaack::Enclave::IndexCandidate.from_indexdef(ddl, types:)
    expect(index.predicate).not_to include("IN ()")
    expect(index.predicate).to include("ANY")
  end
end
