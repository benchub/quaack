# frozen_string_literal: true

require "quaack/enclave/three_configuration_pruning"

# DESIGN.md step 8's three-configuration pruning, against real HypoPG. Each
# configuration compares the rewrite's canonical plan with the original's
# under the same hypothetical indexes.
RSpec.describe Quaack::Enclave::ThreeConfigurationPruning do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "t") }
  let(:original) { "SELECT a FROM public.t WHERE b = $1" }
  let(:literal_sets) { { slow: ["7"] } }

  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS hypopg;
      CREATE TABLE t (a int, b int, c int);
      INSERT INTO t SELECT i, i, i FROM generate_series(1, 100000) AS i;
    SQL
    conn.exec("VACUUM ANALYZE t")
  end

  def index(key, include: [])
    Quaack::Enclave::IndexCandidate.new(table: t, key:, include:, sources: [:parse])
  end

  def discard?(rewrite, original_top:, rewrite_top:)
    described_class.discard?(conn, original:, rewrite:, literal_sets:,
                                   top: { original: original_top, rewrite: rewrite_top })
  end

  let(:covering) { [index(["b"], include: ["a"])] }

  it "discards a rewrite whose plan matches the original's in all three configurations" do
    expect(discard?("SELECT t.a FROM public.t AS t WHERE t.b = $1", original_top: covering, rewrite_top: covering))
      .to be(true)
  end

  it "keeps a rewrite whose bare plan differs" do
    expect(discard?("SELECT a FROM public.t WHERE b = $1 ORDER BY c", original_top: covering, rewrite_top: covering))
      .to be(false)
  end

  it "keeps a rewrite that plans differently only with its own top indexes" do
    # SELECT b needs no heap for an index on b alone, so it scans that index
    # only, and the original, which needs a, doesn't. Bare and with the
    # covering index they plan alike.
    rewrite = "SELECT b FROM public.t WHERE b = $1"
    expect(discard?(rewrite, original_top: covering, rewrite_top: covering)).to be(true)
    expect(discard?(rewrite, original_top: covering, rewrite_top: [index(["b"])])).to be(false)
  end

  it "keeps a rewrite that plans differently only with the original's top indexes" do
    rewrite = "SELECT b FROM public.t WHERE b = $1"
    expect(discard?(rewrite, original_top: [index(["b"])], rewrite_top: covering)).to be(false)
  end

  it "keeps a rewrite when HypoPG refuses an index, since that configuration can't be compared" do
    rewrite = "SELECT t.a FROM public.t AS t WHERE t.b = $1"
    expect(discard?(rewrite, original_top: [index(["ghost"])], rewrite_top: covering)).to be(false)
  end

  it "leaves no hypothetical index, prepared statement, or open transaction" do
    discard?("SELECT b FROM public.t WHERE b = $1", original_top: covering, rewrite_top: [index(["b"])])
    expect(conn.exec("SELECT count(*) FROM hypopg_list_indexes").getvalue(0, 0)).to eq("0")
    expect(conn.exec("SELECT count(*) FROM pg_prepared_statements").getvalue(0, 0)).to eq("0")
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end
end
