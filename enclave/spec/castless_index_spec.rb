# frozen_string_literal: true

require "quaack/enclave/castless_index"
require "quaack/enclave/index_candidate"

# DESIGN.md's negative-result: two spellings of one partial index are one line of the report.
RSpec.describe Quaack::Enclave::CastlessIndex do
  def key(predicate)
    candidate = Quaack::Enclave::IndexCandidate.from_ddl(
      "CREATE INDEX ON public.orders USING btree (id) WHERE #{predicate}", sources: [:llm]
    )
    described_class.key(candidate)
  end

  {
    "a number and the same number as a cast string" => ["amount > 10", "amount > '10'::numeric"],
    "a cast on a column and its constant" => ["status = 'deleted'", "(status)::text = 'deleted'::text"],
    "IN and = ANY of an array" => ["status IN ('a', 'b')", "status = ANY (ARRAY['a'::text, 'b'::text])"],
    "IN and the varchar form a plan prints" =>
      ["status IN ('a', 'b')",
       "(status)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[])"],
    "IN and = ANY of an array literal" => ["id IN (1, 2)", "id = ANY ('{1,2}'::integer[])"]
  }.each do |what, (one, other)|
    it "keys #{what} the same" do
      expect(key(other)).to eq(key(one))
    end
  end

  it "keys different values apart" do
    expect(key("amount > 10")).not_to eq(key("amount > 11"))
    expect(key("status IN ('a', 'b')")).not_to eq(key("status IN ('a', 'c')"))
    expect(key("status IN ('a', 'b')")).not_to eq(key("status <> ALL (ARRAY['a', 'b'])"))
    expect(key("id IN (1, 2)")).not_to eq(key("id = ANY ('{1,3}'::integer[])"))
    expect(key("status NOT IN ('a', 'b')")).not_to eq(key("status <> ANY (ARRAY['a', 'b'])"))
  end

  it "leaves an array literal with quoted, NULL, or nested elements unmerged" do
    ["status = ANY ('{\"a\",b}'::text[])", "id = ANY ('{1,NULL}'::integer[])", "id = ANY ('{{1},{2}}'::integer[])",
     "id = ANY ('{}'::integer[])"].each do |literal|
      expect(key(literal).predicate).not_to include(" IN ")
    end
  end
end
