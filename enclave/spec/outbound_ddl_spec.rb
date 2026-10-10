# frozen_string_literal: true

require "quaack/enclave/candidate_ddl_redaction"
require "quaack/enclave/index_candidate"
require "quaack/enclave/index_store"
require "quaack/enclave/steps/index_build"
require "quaack/enclave/steps/index_feedback"
require "quaack/enclave/steps/index_payload"
require "quaack/enclave/steps/report_payload"

# 20261009-58: each DDL field that leaves the enclave is re-checked by
# CandidateDdlRedaction#redacted? where it's produced.
#
# Every one of these fields is made by CandidateDdlRedaction#ddl, so each is
# in redacted form and the check applies to all. The candidate DDL the LLM
# proposes (index_build's stored ddl) never leaves as it is: it goes out only
# through #ddl, so it's checked like the rest.
RSpec.describe "the DDL fields that leave the enclave" do
  let(:sentinel) { "quaack-sentinel-outbound" }
  let(:outbound) do
    { "tables" => [{ "schema" => "public", "name" => "orders",
                     "columns" => [{ "name" => "status", "most_common_vals" => %w[held open] },
                                   { "name" => "note", "most_common_vals" => nil }] }] }
  end
  let(:redaction) { Quaack::Enclave::CandidateDdlRedaction.new(outbound) }
  # A redaction whose #ddl forgets to mask: what the check is there to catch.
  let(:leaky) do
    Class.new(Quaack::Enclave::CandidateDdlRedaction) { def ddl(candidate) = candidate.to_ddl }.new(outbound)
  end
  let(:planted) { "CREATE INDEX ON public.orders USING btree (id) WHERE note = '#{sentinel}'" }
  let(:realistic) do
    "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held' AND deleted_at IS NULL"
  end
  let(:fixed_message) { "a DDL string isn't in redacted form" }

  def candidate(ddl) = Quaack::Enclave::IndexCandidate.from_ddl(ddl, sources: [:llm])
  def plain(ddl) = Quaack::Enclave::IndexStore.candidate_plain(candidate(ddl))

  def refused(&)
    expect(&).to raise_error(Quaack::Enclave::CandidateDdlRedaction::Error) { |e|
      expect(e.message).to eq(fixed_message)
    }
  end

  describe "CandidateDdlRedaction#outbound_ddl" do
    it "refuses a planted literal with a fixed message that doesn't quote it" do
      refused { leaky.outbound_ddl(candidate(planted)) }
    end

    it "passes a redacted DDL, masking a literal that isn't an MCV value, and a realistic definition" do
      expect(redaction.outbound_ddl(candidate(planted))).to eq(redaction.ddl(candidate(planted)))
      expect(redaction.outbound_ddl(candidate(planted))).not_to include(sentinel)
      expect(redaction.outbound_ddl(candidate(realistic))).to include("status = 'held'")
    end
  end

  # index_payload's candidates and set_aside
  it "refuses a planted literal in index_payload's DDL, and passes a realistic one" do
    refused { Quaack::Enclave::Steps::IndexPayload.candidate(plain(planted), leaky) }
    expect(Quaack::Enclave::Steps::IndexPayload.candidate(plain(realistic), redaction)["ddl"])
      .to eq(redaction.ddl(candidate(realistic)))
  end

  # index_feedback's ddl and beaten_by
  it "refuses a planted literal in index_feedback's DDL, and passes a realistic one" do
    refused { Quaack::Enclave::Steps::IndexFeedback.ddl({ "candidate" => plain(planted) }, leaky) }
    expect(Quaack::Enclave::Steps::IndexFeedback.ddl({ "candidate" => plain(realistic) }, redaction))
      .to eq(redaction.ddl(candidate(realistic)))
  end

  # index_build_progress's ddl
  it "refuses a planted literal in index_build_progress's DDL, and passes a realistic one" do
    refused { Quaack::Enclave::Steps::IndexBuild.shown(leaky, planted) }
    expect(Quaack::Enclave::Steps::IndexBuild.shown(redaction, realistic))
      .to match(/\ACREATE INDEX quaack_\w+ ON public.orders .*status = 'held'/)
  end

  # the report's indexes[].ddl
  it "refuses a planted literal in the report's indexes[].ddl, and passes a realistic one" do
    store = Struct.new(:data) { def read(name) = data.fetch(name) }
    stats = Struct.new(:x) { def table?(_) = false }.new
    run = lambda { |redaction, ddl|
      st = store.new({ "index_build" => { "indexes" => { "quaack_a" => { "ddl" => ddl, "size" => 1 } } },
                       "statistics" => { "tables" => [] } })
      Quaack::Enclave::Steps::ReportPayload.indexes(st, stats, redaction:)
    }

    refused { run.call(leaky, planted) }
    expect(run.call(redaction, realistic)["quaack_a"]["ddl"]).to eq(redaction.ddl(candidate(realistic)))
  end
end
