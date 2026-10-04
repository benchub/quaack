# frozen_string_literal: true

require "quaack/enclave/pii_classification"

# DESIGN.md's classify, for index expressions and statistics objects whose definitions
# fail closed: each is PII, so none of its MCV data leaves, even though the
# columns it keys on are low-cardinality. The inputs are hand-built stored
# statistics and column classes, as PiiClassification.run passes them.
RSpec.describe Quaack::Enclave::PiiClassification do
  let(:mcv) { { "n_distinct" => 3, "most_common_vals" => %w[a b], "most_common_freqs" => [0.5, 0.4] } }
  let(:columns) do
    [["status", false, true], ["kind", false, true], ["email", true, false]].map do |name, pii, low|
      { "schema" => "public", "table" => "t", "column" => name, "pii" => pii, "low_cardinality" => low }
    end
  end

  def outbound(definition)
    table = { "schema" => "public", "name" => "t", "column_names" => %w[status kind email], "columns" => {},
              "indexes" => [{ "name" => "i", "definition" => definition, "columns" => { "lower" => mcv } }],
              "extended_statistics" => [{ "schema" => "public", "name" => "s", "definition" => definition,
                                          "most_common_vals" => [%w[a b]], "most_common_freqs" => [0.5] }] }
    described_class.outbound({ "tables" => [table] }, columns)["tables"].first
  end

  def mcv_data(definition)
    table = outbound(definition)
    index = table["indexes"].first["columns"].first
    stats = table["extended_statistics"].first
    [index["most_common_vals"], index["most_common_freqs"], stats["most_common_vals"], stats["most_common_freqs"]]
  end

  it "lets an index on low-cardinality columns send its MCV data, as the baseline" do
    expect(mcv_data("CREATE INDEX i ON public.t (lower(status), kind)"))
      .to eq([%w[a b], [0.5, 0.4], [%w[a b]], [0.5]])
  end

  it "treats a partial index whose only PII column is in its WHERE clause as PII" do
    expect(mcv_data("CREATE INDEX i ON public.t (lower(status)) WHERE email IS NOT NULL"))
      .to eq([nil, nil, nil, nil])
  end

  it "treats a definition that won't parse as PII" do
    expect(mcv_data("CREATE INDEX i ON public.t (lower(status)")).to eq([nil, nil, nil, nil])
  end

  it "treats a definition naming a column the table doesn't have as PII" do
    expect(mcv_data("CREATE INDEX i ON public.t (lower(status), missing)")).to eq([nil, nil, nil, nil])
  end
end
