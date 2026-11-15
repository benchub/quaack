# frozen_string_literal: true

require "quaack/enclave/rewrite_assumptions"

# DESIGN.md's assumption-check's vocabulary: denormalized_equal, the kind rewrite-rules'
# polymorphic_key_copy states, with every field present and nothing extra.
RSpec.describe Quaack::Enclave::RewriteAssumptions do
  let(:denormalized) do
    { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => "course_id",
      "join_column" => "assignment_id", "references_table" => "public.assignments", "references_column" => "id",
      "type_column" => "context_type", "type_value" => "Course", "id_column" => "context_id" }
  end

  it "accepts a denormalized_equal assumption with exactly its fields" do
    expect(described_class.valid?([denormalized])).to be(true)
  end

  it "refuses one with a field missing, extra, empty, or a table that isn't schema.name" do
    expect([described_class.valid?([denormalized.except("type_value")]),
            described_class.valid?([denormalized.merge("extra" => "x")]),
            described_class.valid?([denormalized.merge("id_column" => "")]),
            described_class.valid?([denormalized.merge("references_table" => "assignments")])])
      .to eq([false, false, false, false])
  end

  describe ".normalized" do
    let(:check) { { "kind" => "check", "table" => "public.orders", "expression" => "total >= 0" } }
    let(:not_null) { { "kind" => "not_null", "table" => "public.orders", "column" => "id" } }

    it "gives the same form for reordered, re-spaced assumptions" do
      spaced = check.merge("expression" => " total \n  >=  0\t")
      expect(described_class.normalized([spaced, not_null])).to eq(described_class.normalized([not_null, check]))
    end

    # Task 20261115-152943-1: a pair only the deparse merges, since
    # collapsing whitespace alone leaves "total>=0" and "total >= 0" apart.
    it "gives the same form for check expressions that differ only in spacing whitespace collapse keeps" do
      tight = check.merge("expression" => "total>=0")
      expect(described_class.normalized([tight])).to eq(described_class.normalized([check]))
    end

    it "gives different forms for really different assumptions" do
      expect(described_class.normalized([check])).not_to eq(described_class.normalized([not_null]))
      other = check.merge("expression" => "total > 0")
      expect(described_class.normalized([check])).not_to eq(described_class.normalized([other]))
    end

    it "keeps the spacing inside a check expression's quoted literal" do
      spaced = check.merge("expression" => "status <> 'a  b'")
      single = check.merge("expression" => "status <> 'a b'")
      expect(described_class.normalized([spaced])).not_to eq(described_class.normalized([single]))
    end

    it "compares an expression that doesn't parse exactly as given" do
      expect(described_class.normalized([check.merge("expression" => "status <> 'a  b")]))
        .not_to eq(described_class.normalized([check.merge("expression" => "status <> 'a b")]))
      expect(described_class.normalized([check.merge("expression" => " total >=")]).first["expression"])
        .to eq(" total >=")
    end

    it "keeps a column list's order, which a foreign key pairs on" do
      fk = { "kind" => "foreign_key", "table" => "public.a", "columns" => %w[x y],
             "references_table" => "public.b", "references_columns" => %w[p q] }
      expect(described_class.normalized([fk]))
        .not_to eq(described_class.normalized([fk.merge("references_columns" => %w[q p])]))
    end
  end
end
