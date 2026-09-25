# frozen_string_literal: true

require "quaack/enclave/generator_three"
require "quaack/enclave/generator_one"
require "quaack/enclave/egress"

# The inbound check reads the catalog, so these run against real Postgres,
# on the sample schema (public.orders and public.customers).
RSpec.describe Quaack::Enclave::GeneratorThree do
  let(:conn) { test_database.connection }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:customers) { Quaack::Enclave::TableName.new(schema: "public", name: "customers") }
  let(:tables) { [orders, customers] }
  let(:sentinel) { "quaack-sentinel-5a5" }

  def existing(sql) = Quaack::Enclave::IndexCandidate.from_ddl(sql, sources: [:existing])

  let(:orders_index) do
    existing("CREATE INDEX orders_status_created_at_idx ON public.orders USING btree (status, created_at)")
  end

  let(:statistics) do
    table = lambda do |name, column_names, indexes|
      Quaack::Enclave::TableStatistics.new(name:, reltuples: 1000, columns: {}, column_names:, indexes:)
    end
    order_columns = %w[id customer_id status total_cents created_at]
    tables = [table[orders, order_columns, { "orders_status_created_at_idx" => orders_index }],
              table[customers, %w[id name email created_at], {}]]
    Quaack::Enclave::Statistics.new(tables:)
  end

  let(:dedupe) { Quaack::Enclave::Dedupe.new(statistics:, low_cardinality: [[orders, "status"]]) }

  def filter(ddls) = described_class.filter(ddls, dedupe:, tables:, settings: nil, connection: conn)

  def outcome_fields(result)
    result.outcomes.map { [it.index, it.status, it.rule, it.covered_by, it.partial_constant_only] }
  end

  it "accepts a candidate the mechanical generators missed, as an LLM candidate for 5a-4" do
    result = filter(["CREATE INDEX ON public.customers (email text_pattern_ops)"])

    expect(outcome_fields(result)).to eq([[1, :accepted, nil, nil, false]])
    expect(result.survivors.map(&:to_ddl))
      .to eq(["CREATE INDEX ON public.customers USING btree (email text_pattern_ops)"])
    expect(result.survivors.map { it.sources.to_a }).to eq([[:llm]])
    expect(dedupe.proposals).to eq(result.survivors)
  end

  it "drops DDL the inbound check refuses, with its rule, such as an unqualified table" do
    result = filter(["CREATE INDEX ON customers (lower(email))",
                     "CREATE INDEX ON public.orders (created_at) WITH (fillfactor = 70)"])

    expect(outcome_fields(result)).to eq([[1, :dropped, "unqualified_table", nil, false],
                                          [2, :dropped, "storage_options", nil, false]])
    expect(result.survivors).to eq([])
  end

  it "drops a candidate an existing index covers, naming the index" do
    result = filter(["CREATE INDEX ON public.orders (status)"])

    expect(outcome_fields(result)).to eq([[1, :dropped, "covered_by_existing", "orders_status_created_at_idx", false]])
  end

  it "drops a candidate a mechanical generator already proposed, adding llm to its sources" do
    mechanical = Quaack::Enclave::IndexCandidate.new(table: orders, key: %w[customer_id created_at],
                                                     sources: [:parse])
    dedupe.filter([mechanical])

    result = filter(["CREATE INDEX ON public.orders (customer_id, created_at)"])

    expect(outcome_fields(result)).to eq([[1, :dropped, "duplicate", nil, false]])
    expect(dedupe.proposals.map { it.sources.to_a }).to eq([%i[parse llm]])
  end

  it "tags a partial candidate on a low-cardinality column, and drops one on any other column" do
    result = filter(["CREATE INDEX ON public.orders (created_at) WHERE status <> 'delivered'",
                     "CREATE INDEX ON public.orders (created_at) WHERE customer_id = 7"])

    expect(outcome_fields(result)).to eq([[1, :accepted, nil, nil, true],
                                          [2, :dropped, "partial_not_low_cardinality", nil, false]])
    expect(result.survivors.map(&:predicate)).to eq(["status <> 'delivered'"])
  end

  it "sets aside a GIN candidate, untested, and drops one IndexCandidate can't represent" do
    conn.exec("CREATE EXTENSION pg_trgm")
    result = filter(["CREATE INDEX ON public.customers USING gin (email gin_trgm_ops)",
                     "CREATE INDEX ON public.customers USING gist (email gist_trgm_ops(siglen=32))"])

    expect(outcome_fields(result)).to eq([[1, :set_aside, nil, nil, false],
                                          [2, :dropped, "unrepresentable", nil, false]])
    expect(result.survivors).to eq([])
    expect(dedupe.set_aside.map(&:access_method)).to eq([:gin])
  end

  it "takes at most five, dropping the rest unchecked" do
    ddls = ["id", "customer_id", "total_cents", "created_at", "total_cents, created_at"]
           .map { "CREATE INDEX ON public.orders (#{it})" }
    result = filter([*ddls, "not even SQL"])

    expect(result.outcomes.map(&:status)).to eq([*[:accepted] * 5, :dropped])
    expect(result.outcomes.last.rule).to eq("too_many")
    expect(dedupe.considered).to eq(5)
  end

  it "refuses anything but an Array of Strings, without quoting it" do
    expect { filter(sentinel) }.to raise_error(ArgumentError) { expect(it.message).not_to include(sentinel) }
    expect { filter([1]) }.to raise_error(ArgumentError) { expect(it.message).not_to include(sentinel) }
  end

  describe "messages" do
    let(:planted) do
      ["CREATE INDEX ON public.orders (created_at) WHERE customer_id::text = '#{sentinel}'",
       "CREATE INDEX ON orders (created_at) WHERE status = '#{sentinel}'",
       "CREATE INDEX ON public.orders ((lower('#{sentinel}') || status))",
       "CREATE INDEX ON public.orders (created_at) WHERE status = '#{sentinel}'"]
    end

    it "goes out through egress as shape only: position, outcome, rule, covering index, and tag" do
      lines = described_class.messages(filter(planted)).map { Quaack::Enclave::Egress.serialize(it) }

      expected = [[1, "dropped", "partial_not_low_cardinality", false], [2, "dropped", "unqualified_table", false],
                  [3, "accepted", nil, false], [4, "accepted", nil, true]].map do |index, outcome, rule, tag|
        { "type" => "index_outcome", "index" => index, "outcome" => outcome, "rule" => rule, "covered_by" => nil,
          "partial_constant_only" => tag }
      end
      expect(lines.map { JSON.parse(it) }).to eq(expected)
    end

    it "never carries the DDL, so a planted sentinel never shows up" do
      result = filter(planted)
      expect(result.survivors.map(&:to_ddl).join).to include(sentinel)

      lines = described_class.messages(result).map { Quaack::Enclave::Egress.serialize(it) }
      expect(lines.join).not_to include(sentinel)
      expect(result.outcomes.map(&:inspect).join).not_to include(sentinel)
    end
  end
end
