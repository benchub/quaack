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

  # 20261009-50: the re-check on a DDL string that is about to leave.
  describe "#redacted?" do
    def redacted?(ddl) = redaction.redacted?(ddl)

    it "passes what #ddl makes, however the candidate's constants were masked or kept" do
      expression = Quaack::Enclave::IndexCandidate::KeyColumn.new(expression: "coalesce(note, '#{sentinel}')")
      ddls = [candidate(predicate: "status = 'held' AND note = '#{sentinel}' AND total = 7"),
              candidate(predicate: "status = ANY (ARRAY['held', '#{sentinel}']) AND note IS NULL"),
              candidate(key: [expression])]

      ddls.each { |c| expect(redacted?(redaction.ddl(c))).to be(true), redaction.ddl(c) }
    end

    it "passes ordinary realistic definitions: IS NULL, an expression index, INCLUDE columns, a kept MCV value" do
      [
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE deleted_at IS NULL",
        "CREATE INDEX ON public.orders USING btree (lower(note))",
        "CREATE INDEX ON public.orders USING btree (created_at) INCLUDE (total, note)",
        "CREATE INDEX orders_status_idx ON public.orders USING btree (status) WHERE status = 'held'",
        "CREATE UNIQUE INDEX ON public.orders USING btree (id) WHERE note IS NULL AND status IN ('held', 'open')"
      ].each { |ddl| expect(redacted?(ddl)).to be(true), ddl }
    end

    it "refuses a literal in a predicate that isn't one of the column's values, without a way to quote it" do
      [
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE note = '#{sentinel}'",
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = '#{sentinel}'",
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE note = 'held'",
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE total > 7 AND status = 'held'",
        "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = ANY('{held,#{sentinel}}'::text[])",
        "CREATE INDEX ON public.customers USING btree (id) WHERE tier = 'held'",
        "CREATE INDEX ON public.orders USING btree (coalesce(note, '#{sentinel}'))",
        "CREATE INDEX ON public.orders USING btree ((status = 'held'))"
      ].each { |ddl| expect(redacted?(ddl)).to be(false), ddl }
    end

    it "refuses what isn't one CREATE INDEX, or isn't SQL, and a table the payload says nothing of" do
      ["", "SELECT 1", "CREATE INDEX ON public.orders (id); SELECT '#{sentinel}'", "not sql #{sentinel}",
       "CREATE INDEX ON public.unknown USING btree (id) WHERE a = 'x'"].each do |ddl|
        expect(redacted?(ddl)).to be(false), ddl
      end
      expect(redacted?(nil)).to be(false)
    end
  end
end
