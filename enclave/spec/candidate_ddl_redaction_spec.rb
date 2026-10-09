# frozen_string_literal: true

require "quaack/enclave/candidate_ddl_redaction"
require "quaack/enclave/index_candidate"

RSpec.describe Quaack::Enclave::CandidateDdlRedaction do
  let(:sentinel) { "quaack-sentinel-ddl" }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:outbound) do
    { "tables" => [
      { "schema" => "public", "name" => "orders",
        "columns" => [{ "name" => "status", "most_common_vals" => %w[held open 7] },
                      { "name" => "note", "most_common_vals" => nil }] },
      { "schema" => "public", "name" => "customers",
        "columns" => [{ "name" => "tier", "most_common_vals" => [sentinel] }] }
    ] }
  end
  let(:redaction) { described_class.new(outbound) }

  def candidate(predicate: nil, key: ["created_at"])
    Quaack::Enclave::IndexCandidate.new(table: orders, key:, predicate:, sources: [:plan])
  end

  it "keeps a constant only where it's compared directly with the low-cardinality column it's a value of" do
    ddl = redaction.ddl(candidate(predicate: "status = 'held' AND note = '#{sentinel}' AND total = 7 " \
                                             "AND 'open' <> status::text AND status IN ('7', 'x') AND note = 'held'"))

    expect(ddl).to eq("CREATE INDEX ON public.orders USING btree (created_at) " \
                      "WHERE 'open' <> status::text AND note = ? AND note = ? AND status = 'held' " \
                      "AND status IN ('7', ?) AND total = ?")
  end

  it "keeps allowed values in col = ANY (...), the way Postgres prints an IN list, and masks the rest" do
    ddl = redaction.ddl(candidate(predicate: "status = ANY (ARRAY['held', '#{sentinel}']) " \
                                             "AND status = ANY ('{held,open}'::text[]) " \
                                             "AND status = ANY ('{held,#{sentinel}}'::text[]) " \
                                             "AND note = ANY (ARRAY['held'])"))

    expect(ddl).to eq("CREATE INDEX ON public.orders USING btree (created_at) " \
                      "WHERE note = ANY(ARRAY[?]) AND status = ANY('{held,open}'::text[]) " \
                      "AND status = ANY(?::text[]) AND status = ANY(ARRAY['held', ?])")
  end

  it "masks a low-cardinality value inside a key expression or function argument" do
    key = [Quaack::Enclave::IndexCandidate::KeyColumn.new(expression: "(status = 'held')")]
    ddl = redaction.ddl(candidate(key:, predicate: "coalesce(status, 'held') = 'open'"))

    expect(ddl).to eq("CREATE INDEX ON public.orders USING btree ((status = ?)) WHERE COALESCE(status, ?) = ?")
  end

  it "masks constants in key expressions" do
    key = [Quaack::Enclave::IndexCandidate::KeyColumn.new(expression: "coalesce(note, '#{sentinel}')")]

    expect(redaction.ddl(candidate(key:))).to eq("CREATE INDEX ON public.orders USING btree (COALESCE(note, ?))")
  end

  it "allows only values of the candidate's own table, and keeps NULL" do
    ddl = redaction.ddl(candidate(predicate: "status = '#{sentinel}' OR status IS DISTINCT FROM NULL"))

    expect(ddl).not_to include(sentinel)
    expect(ddl).to end_with("WHERE status = ? OR status IS DISTINCT FROM NULL")
  end

  # 20260923-36: Dedupe now lets a no-literal partial through on any column.
  it "passes a no-literal partial on a non-low-cardinality column through with nothing to mask" do
    ddl = redaction.ddl(candidate(predicate: "note IS NULL AND deleted_at IS NOT NULL AND NOT archived"))

    expect(ddl).to eq("CREATE INDEX ON public.orders USING btree (created_at) " \
                      "WHERE NOT archived AND deleted_at IS NOT NULL AND note IS NULL")
  end
end
