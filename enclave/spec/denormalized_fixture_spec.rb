# frozen_string_literal: true

require "quaack/enclave/denormalized_fixture"
require "quaack/enclave/table_name"

# Which denormalized_equal assumptions steps 9 and 10 honour in their
# fixtures for one stored rewrite (DESIGN.md 6c, 9, 10a): its own, and only
# when a 6c rule wrote it.
RSpec.describe Quaack::Enclave::DenormalizedFixture do
  let(:assumption) do
    { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => "course_id",
      "join_column" => "assignment_id", "references_table" => "canvas.assignments", "references_column" => "id",
      "type_column" => "context_type", "type_value" => "Course", "id_column" => "context_id" }
  end
  let(:not_null) { { "kind" => "not_null", "table" => "public.submissions", "column" => "body" } }

  def entry(source, assumptions = [not_null, assumption]) = { "source" => source, "assumptions" => assumptions }
  def table(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  it "copies a rule's denormalized_equal assumptions, with their tables split, and nothing else" do
    expect(described_class.copies(entry("rule"))).to eq(
      [described_class::Copy.new(table: table("public", "submissions"), column: "course_id",
                                 join_column: "assignment_id", references_table: table("canvas", "assignments"),
                                 references_column: "id", type_column: "context_type", type_value: "Course",
                                 id_column: "context_id")]
    )
  end

  it "honours nothing from the LLM, an operator, or an entry with no source" do
    expect(%w[llm operator].map { described_class.copies(entry(it)) }).to eq([[], []])
    expect(described_class.copies({ "assumptions" => [assumption] })).to eq([])
  end

  it "honours nothing for a rule's rewrite without the assumption" do
    expect(described_class.copies(entry("rule", [not_null]))).to eq([])
  end
end
