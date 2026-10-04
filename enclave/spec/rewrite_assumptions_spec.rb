# frozen_string_literal: true

require "quaack/enclave/rewrite_assumptions"

# DESIGN.md's assumption-check's vocabulary: denormalized_equal, the kind rewrite-rules's
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
end
