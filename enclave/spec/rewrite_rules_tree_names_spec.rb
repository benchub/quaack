# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/rewrite_rules/tree"

# Tree::Names, which every rule that makes a fresh alias shares:
# key_in_self_join, not_in_to_not_exists, existence_in_flip, and
# or_to_union. Postgres cuts a name longer than 63 bytes down to 63, so a
# fresh name that long could come out as a name the query already uses,
# or as another fresh one (task 20261002-5).
RSpec.describe Quaack::Enclave::RewriteRules::Tree::Names do
  def names(sql) = described_class.new(PgQuery.parse(sql).tree)

  it "adds _1, _2, ... to the base, skipping names the query uses" do
    fresh = names("SELECT t.id_1 FROM public.t")
    expect([fresh.fresh("id"), fresh.fresh("id"), fresh.fresh("t")]).to eq(%w[id_2 id_3 t_1])
  end

  it "cuts a long base so the name fits in 63 bytes, and is still new" do
    long = "c" * 63
    fresh = names("SELECT t.#{long}, t.#{"c" * 61}_1 FROM public.t")

    made = [fresh.fresh(long), fresh.fresh(long), fresh.fresh("c" * 62)]

    expect(made).to eq(["#{"c" * 61}_2", "#{"c" * 61}_3", "#{"c" * 61}_4"])
  end

  # The parser cuts a name over 63 bytes as Postgres does, so the names
  # Names sees are already cut, and a fresh name can't equal a long name's
  # cut form (task 20261007-46).
  it "skips a name that's what the parser cuts a longer name the query uses down to" do
    fresh = names("SELECT t.#{"x" * 61}_1_more, t.#{"é" * 30}_1éé FROM public.t")

    expect([fresh.fresh("x" * 62), fresh.fresh("é" * 31)]).to eq(["#{"x" * 61}_2", "#{"é" * 30}_2"])
  end

  it "cuts a multibyte base at a character, not inside one" do
    made = names("SELECT 1").fresh("é" * 31)

    expect([made, made.bytesize, made.valid_encoding?]).to eq(["#{"é" * 30}_1", 62, true])
  end

  it "makes names Postgres keeps as written" do
    fresh = names("SELECT 1")
    made = Array.new(12) { fresh.fresh("d" * 62) }

    kept = made.map { PgQuery.parse("SELECT 1 AS #{it}").tree.stmts.first.stmt.select_stmt.target_list.first }
    expect(kept.map { it.res_target.name }).to eq(made)
    expect(made.uniq.size).to eq(12)
  end
end
