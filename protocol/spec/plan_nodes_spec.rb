# frozen_string_literal: true

require "open3"
require "rbconfig"
require "quaack/protocol/plan_nodes"

# The one check on what a plan node in a report may carry, for the enclave's
# egress function and the driver both.
RSpec.describe Quaack::Protocol::PlanNodes do
  let(:sentinel) { "SENTINEL_PLAN_NODE_7f3a" }
  let(:node) do
    { "node" => "Index Scan", "relation" => "public.orders", "index" => "orders_pkey", "est_rows" => 5,
      "actual_rows" => 4.5, "selectivity" => 0.005, "depth" => 1 }
  end

  def valid?(plan) = described_class.valid?(plan)

  it "lists a node's fields: its type, relation, index name, row counts, selectivity, and depth" do
    expect(described_class::FIELDS).to eq(%w[node relation index est_rows actual_rows selectivity depth])
    expect(described_class::FIELDS).to be_frozen.and(all(be_frozen))
  end

  it "takes a plan of nodes with exactly those fields, in any order, and an empty plan" do
    top = { "node" => "Limit", "relation" => nil, "index" => nil, "est_rows" => nil, "actual_rows" => nil,
            "selectivity" => nil, "depth" => 0 }
    expect(valid?([top, node, node.to_a.reverse.to_h])).to be(true)
    expect(valid?([])).to be(true)
  end

  it "refuses a plan that isn't an Array of Hashes" do
    [nil, {}, node, "Seq Scan", [[node]], [nil], [node.to_a]].each do |bad|
      expect(valid?(bad)).to be(false), bad.inspect
    end
  end

  it "refuses a node with a field that isn't one of them, such as a planted sentinel" do
    expect(valid?([node.merge(sentinel => 1)])).to be(false)
    expect(valid?([node.merge("filter" => sentinel)])).to be(false)
    expect(valid?([node, node.merge("Index Cond" => "(id = '#{sentinel}')")])).to be(false)
  end

  it "refuses a node missing one of them" do
    described_class::FIELDS.each { expect(valid?([node.except(it)])).to be(false), it }
  end

  it "refuses a node whose fields are Symbols, as JSON never reads one back, even mixed with Strings" do
    expect(valid?([node.transform_keys(&:to_sym)])).to be(false)
    expect(valid?([node.merge(sentinel.to_sym => 1)])).to be(false)
  end

  it "refuses a type that isn't a String" do
    [nil, 1, :Limit, ["Limit"], { "a" => "b" }].each do |bad|
      expect(valid?([node.merge("node" => bad)])).to be(false), bad.inspect
    end
  end

  it "refuses a relation or index name that isn't a String or nil" do
    [1, :orders, [sentinel], { sentinel => 1 }, true].each do |bad|
      expect(valid?([node.merge("relation" => bad)])).to be(false), bad.inspect
      expect(valid?([node.merge("index" => bad)])).to be(false), bad.inspect
    end
  end

  it "refuses a row count or selectivity that isn't a number or nil" do
    ["5", sentinel, true, [5], { "rows" => 5 }].each do |bad|
      %w[est_rows actual_rows selectivity].each do |field|
        expect(valid?([node.merge(field => bad)])).to be(false), "#{field}: #{bad.inspect}"
      end
    end
  end

  it "refuses a depth that isn't an Integer of zero or more" do
    [nil, -1, 1.0, "1", true, [1]].each do |bad|
      expect(valid?([node.merge("depth" => bad)])).to be(false), bad.inspect
    end
  end

  it "is loaded by quaack/protocol" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::PlanNodes::FIELDS.join(",")')
    end

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq(described_class::FIELDS.join(","))
  end
end
