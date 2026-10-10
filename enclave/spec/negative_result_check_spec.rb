# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/enclave/steps/negative_result"
require "quaack/enclave/store"

# 20261009-50: every DDL string in report's negative field is checked
# on the way out, by the same redaction rules that made it.
RSpec.describe Quaack::Enclave::Steps::NegativeResult do
  let(:sentinel) { "SENTINEL_NEGATIVE_DDL_91b2" }
  let(:outbound) do
    { "tables" => [{ "schema" => "public", "name" => "orders",
                     "columns" => [{ "name" => "status", "most_common_vals" => %w[held open] },
                                   { "name" => "note", "most_common_vals" => nil }] }] }
  end
  let(:redaction) { Quaack::Enclave::CandidateDdlRedaction.new(outbound) }
  let(:clean) { "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held' AND note = ?" }
  let(:fixed_message) { "a DDL string in this negative result isn't redacted" }

  # A redaction with the bug the check guards against: it lets the DDL out as it came.
  let(:leaky) do
    Class.new(Quaack::Enclave::CandidateDdlRedaction) { def ddl(candidate) = candidate.to_ddl }.new(outbound)
  end

  def negative(declined: [], existing: []) = { "declined" => declined, "existing" => existing }

  def existing(ddl: clean, definition: clean)
    { "ddl" => ddl, "covered_by" => { "name" => "orders_note_idx", "size_bytes" => 8192, "definition" => definition },
      "searches" => ["original"] }
  end

  def declined(ddl) = { "ddl" => ddl, "reason" => "unused", "sqlstate" => nil, "searches" => ["original"] }

  def planted = "CREATE INDEX ON public.orders USING btree (created_at) WHERE note = '#{sentinel}'"

  def refused(payload) = expect { described_class.verify!(payload, redaction) }.to raise_error(described_class::Error)

  it "passes redacted DDL, ordinary definitions, and a covered_by with no definition" do
    realistic = ["CREATE INDEX ON public.orders USING btree (created_at) WHERE deleted_at IS NULL",
                 "CREATE INDEX ON public.orders USING btree (lower(note))",
                 "CREATE INDEX ON public.orders USING btree (created_at) INCLUDE (total, note)"]
    payload = negative(declined: [clean, *realistic].map { declined(it) },
                       existing: [existing, existing(definition: realistic[0]), existing(definition: nil)])

    expect(described_class.verify!(payload, redaction)).to eq(payload)
  end

  it "refuses a literal planted in a declined index's ddl, an existing index's ddl, or a definition" do
    refused(negative(declined: [declined(clean), declined(planted)]))
    refused(negative(existing: [existing(ddl: planted)]))
    refused(negative(existing: [existing(definition: planted)]))
  end

  it "refuses with a fixed message that doesn't quote the DDL" do
    expect { described_class.verify!(negative(declined: [declined(planted)]), redaction) }
      .to raise_error(described_class::Error) { |e| expect([e.message, e.cause]).to eq([fixed_message, nil]) }
  end

  it "refuses a DDL field that isn't a String, and a malformed negative" do
    refused(negative(declined: [declined(nil)]))
    refused(negative(declined: [declined(7)]))
    refused(negative(declined: [{ "reason" => "unused" }]))
    refused("declined" => "CREATE INDEX #{sentinel}", "existing" => [])
  end

  describe ".call" do
    around do |example|
      Dir.mktmpdir("quaack-negative-check-spec") do |tmp|
        @base = File.join(tmp, "runs")
        example.run
      end
    end

    let(:store) do
      Quaack::Enclave::Store.create(base: @base).tap do |store|
        store.write("classification", "outbound_statistics" => outbound)
        store.write("statistics", "tables" => [{ "schema" => "public", "name" => "orders", "indexes" => [] }])
        store.write("index_search_original", "results" => [result], "llm_results" => [])
      end
    end

    def result
      candidate = Quaack::Enclave::IndexCandidate.from_ddl(planted, sources: [:generator_one])
      { "candidate" => Quaack::Enclave::IndexStore.candidate_plain(candidate), "size" => 8192, "refusal" => nil,
        "plans" => { "slow" => { "used" => false, "total_cost" => 1.0 } } }
    end

    it "sends the declined index with its literal masked" do
      declined = described_class.call(store)["declined"]

      expect(declined.map { it["ddl"] })
        .to eq(["CREATE INDEX ON public.orders USING btree (created_at) WHERE note = ?"])
    end

    it "refuses to send a DDL that came out of the redaction with the literal in it" do
      expect { described_class.call(store, redaction: leaky) }
        .to raise_error(described_class::Error) { |e| expect(e.message).not_to include(sentinel) }
    end
  end
end
