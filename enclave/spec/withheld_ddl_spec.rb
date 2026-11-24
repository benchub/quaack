# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/candidate_ddl_redaction"
require "quaack/enclave/index_candidate"
require "quaack/enclave/index_store"
require "quaack/enclave/internal_error_log"
require "quaack/enclave/steps/index_feedback"
require "quaack/enclave/steps/index_payload"
require "quaack/enclave/steps/report_payload"

# 20261124-233000-1: a candidate whose DDL fails the outbound check is
# withheld, fail-closed, instead of ending the step, and its shape (never
# its text) goes to the run's internal_errors.log.
RSpec.describe "withholding a candidate whose DDL fails the outbound check" do
  let(:sentinel) { "quaack_sentinel_withheld" }
  let(:outbound) do
    { "tables" => [{ "schema" => "public", "name" => "orders",
                     "columns" => [{ "name" => "status", "most_common_vals" => %w[held open] }] }] }
  end
  # A redaction whose #ddl forgets to mask, so its check fails for a literal.
  let(:leaky) do
    Class.new(Quaack::Enclave::CandidateDdlRedaction) { def ddl(candidate) = candidate.to_ddl }.new(outbound)
  end
  let(:bad) do
    "CREATE INDEX ON public.#{sentinel}_t USING btree (#{sentinel}_c COLLATE #{sentinel}_coll) " \
      "WHERE #{sentinel}_d = '#{sentinel}_v' AND n = 424242"
  end
  let(:good) { "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held'" }

  def candidate(ddl) = Quaack::Enclave::IndexCandidate.from_ddl(ddl, sources: [:llm])
  def plain(ddl) = Quaack::Enclave::IndexStore.candidate_plain(candidate(ddl))

  describe "CandidateDdlRedaction#withholding_ddl" do
    it "returns nil for a DDL that fails the check, and records its shape" do
      expect(leaky.withholding_ddl(candidate(bad))).to be_nil
      expect(leaky.withheld.size).to eq(1)
      expect(leaky.withheld.first).to start_with("IndexStmt(")
    end

    it "returns the redacted DDL for one that passes, recording nothing" do
      expect(leaky.withholding_ddl(candidate(good))).to eq(good)
      expect(leaky.withheld).to eq([])
    end
  end

  describe Quaack::Enclave::DdlFingerprint do
    it "names the parse-node kinds only, never an identifier, collation, or constant" do
      print = described_class.of(bad)
      expect(print).to match(/\AIndexStmt\(RangeVar,IndexElem\(String\).*AConst/)
      expect(print).not_to include(sentinel)
      expect(print).not_to include("424242")
      expect(print).to match(described_class::SHAPE)
    end

    it "is unparsable for text that isn't SQL" do
      expect(described_class.of("CREATE INDEX ((")).to eq("unparsable")
    end
  end

  describe "InternalErrorLog.withheld" do
    it "appends a line with the step and the shape, and never a sentinel" do
      Dir.mktmpdir do |dir|
        Quaack::Enclave::InternalErrorLog.withheld(dir, step: "index-feedback",
                                                        fingerprint: Quaack::Enclave::DdlFingerprint.of(bad),
                                                        now: Time.utc(2026, 11, 24, 23, 30, 0))
        text = File.read(File.join(dir, "internal_errors.log"))
        expect(text).to match(/\A2026-11-24T23:30:00Z step=index-feedback withheld_ddl=IndexStmt\(\S+\)\n\z/)
        expect(text).not_to include(sentinel)
        expect(File.stat(File.join(dir, "internal_errors.log")).mode & 0o777).to eq(0o600)
      end
    end

    it "writes none for a planted fingerprint that isn't plain shape" do
      Dir.mktmpdir do |dir|
        Quaack::Enclave::InternalErrorLog.withheld(dir, step: "index-feedback", fingerprint: "IndexStmt(#{sentinel})",
                                                        now: Time.utc(2026, 11, 24))
        text = File.read(File.join(dir, "internal_errors.log"))
        expect(text).to end_with("withheld_ddl=none\n")
        expect(text).not_to include(sentinel)
      end
    end
  end

  def entry(results)
    { "baseline" => { "slow" => { "total_cost" => 100.0, "plan" => [] } }, "results" => results,
      "llm_results" => results, "dedupe" => { "set_aside" => [plain(bad)] } }
  end

  def result(ddl)
    { "candidate" => plain(ddl), "size" => 1, "refusal" => nil, "partial_constant_only" => false,
      "plans" => { "slow" => { "used" => true, "total_cost" => 50.0 } } }
  end

  it "index-feedback drops the withheld candidate, counts it, and keeps the rest" do
    message = Quaack::Enclave::Steps::IndexFeedback.message(entry([result(bad), result(good)]), leaky)
    expect(message[:candidates].map { it["ddl"] }).to eq([good])
    expect(message[:withheld]).to eq(1)
    expect(JSON.generate(message)).not_to include(sentinel)
  end

  it "logs each withheld candidate's shape to the run's internal_errors.log, never its text" do
    Dir.mktmpdir do |dir|
      Quaack::Enclave::Steps::IndexFeedback.message(entry([result(bad), result(good)]), leaky)
      Quaack::Enclave::Steps::IndexFeedback.log_withheld(Struct.new(:path).new(dir), "index-feedback", leaky)
      lines = File.readlines(File.join(dir, "internal_errors.log"))
      expect(lines.size).to eq(1)
      expect(lines.first).to match(/ step=index-feedback withheld_ddl=IndexStmt\(RangeVar,IndexElem/)
      expect(lines.first).not_to include(sentinel)
    end
  end

  it "index-payload drops withheld candidates and set-asides, and counts them" do
    mechanical = Quaack::Enclave::Steps::IndexPayload.mechanical(entry([result(bad), result(good)]), leaky)
    expect(mechanical["candidates"].map { it["ddl"] }).to eq([good])
    expect(mechanical["set_aside"]).to eq([])
    expect(mechanical["withheld"]).to eq(2)
    expect(JSON.generate(mechanical)).not_to include(sentinel)
  end

  it "the report's indexes[].ddl is nil for a withheld index" do
    store = Struct.new(:data) do
      def read(name) = data.fetch(name)
      def entry?(name) = data.key?(name)
    end.new({ "index_build" => { "indexes" => { "quaack_x" => { "ddl" => bad, "size" => 1 } } },
              "statistics" => { "tables" => [] } })
    stats = Struct.new(:x) { def table?(_) = false }.new
    indexes = Quaack::Enclave::Steps::ReportPayload.indexes(store, stats, redaction: leaky)
    expect(indexes["quaack_x"]["ddl"]).to be_nil
    expect(leaky.withheld.size).to eq(1)
  end
end
