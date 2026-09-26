# frozen_string_literal: true

require "json"
require "quaack/enclave/index_store"

# IndexStore: IndexCandidate and Dedupe as plain store data and back.
RSpec.describe Quaack::Enclave::IndexStore do
  let(:key_column) { Quaack::Enclave::IndexCandidate::KeyColumn }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:low_cardinality) { [[orders, "status"]] }

  def candidate(key, sources: [:parse], **) = Quaack::Enclave::IndexCandidate.new(table: orders, key:, sources:, **)

  def statistics(indexes = {})
    table = Quaack::Enclave::TableStatistics.new(name: orders, reltuples: 1000, columns: {},
                                                 column_names: %w[id status created_at total email], indexes:)
    Quaack::Enclave::Statistics.new(tables: [table])
  end

  # Through JSON, as the store keeps it.
  def through_json(plain) = JSON.parse(JSON.generate(plain))

  let(:rich) do
    candidate(["status", key_column.new(name: "created_at", direction: :desc, nulls: :last),
               key_column.new(expression: "lower(email)", opclass: "text_pattern_ops", collation: "C")],
              include: ["total"], predicate: "status = 'open'", sources: %i[parse plan])
  end

  it "round-trips a candidate with every member set, sources included" do
    back = described_class.candidate(through_json(described_class.candidate_plain(rich)))

    expect(back).to eq(rich)
    expect(back.to_h).to eq(rich.to_h)
    expect(back.to_ddl).to eq(rich.to_ddl)
  end

  it "round-trips a unique candidate" do
    plain = candidate(["id"], unique: true, sources: [:existing])

    expect(described_class.candidate(through_json(described_class.candidate_plain(plain))).to_h).to eq(plain.to_h)
  end

  it "round-trips a non-btree method" do
    brin = candidate(["created_at"], access_method: :brin)

    expect(described_class.candidate(through_json(described_class.candidate_plain(brin))).to_h).to eq(brin.to_h)
  end

  describe "Dedupe" do
    let(:existing) { candidate(%w[status created_at], sources: [:existing]) }

    def filled
      search = Quaack::Enclave::Dedupe.new(statistics: statistics("orders_status_idx" => existing), low_cardinality:)
      search.filter([candidate(["status"]), candidate(%w[total id]), candidate(["email"], access_method: :gin),
                     candidate(["id"], predicate: "email = 'x@y.z'")])
      search.filter([candidate(%w[total id], sources: [:plan])])
      search
    end

    def restore(plain)
      described_class.dedupe(through_json(plain), statistics: statistics("orders_status_idx" => existing),
                                                  low_cardinality:)
    end

    def summary(search)
      { proposals: search.proposals.map(&:to_h), set_aside: search.set_aside.map(&:to_h),
        drops: search.drops.map { [it.candidate.to_h, it.reason, it.covered_by&.to_h] },
        considered: search.considered }
    end

    it "round-trips proposals, set-aside candidates, every kind of drop, and the count" do
      search = filled
      expect(search.drops.map(&:reason)).to eq(%i[covered_by_existing partial_not_low_cardinality duplicate])

      back = restore(described_class.dedupe_plain(search))

      expect(summary(back)).to eq(summary(search))
      expect(back.drops.first.covered_by).to be_a(Quaack::Enclave::Dedupe::ExistingIndex)
      expect(back.drops.last.covered_by).to be_a(Quaack::Enclave::IndexCandidate)
    end

    it "keeps filtering as the original would, merging a later duplicate's sources" do
      back = restore(described_class.dedupe_plain(filled))

      expect(back.filter([candidate(%w[total id], sources: [:llm])])).to eq([])
      expect(back.proposals.find { it.key.map(&:name) == %w[total id] }.sources.to_a.sort).to eq(%i[llm parse plan])
      expect(back.considered).to eq(6)
    end
  end
end
