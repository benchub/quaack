# frozen_string_literal: true

require "quaack/enclave/index_candidate"

RSpec.describe "predicate operand order" do
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }

  def predicate(sql)
    Quaack::Enclave::IndexCandidate.new(table: orders, key: ["a"], sources: [:parse], predicate: sql).predicate
  end

  # Task 20261009-17.
  it "sorts each AND and OR's operands, without moving any across a boundary" do
    {
      "c = 3 AND b = 2 AND a = 1" => "a = 1 AND b = 2 AND c = 3",
      "c = 3 OR (b = 2 AND a = 1)" => "(a = 1 AND b = 2) OR c = 3",
      "z = 1 AND (y IS NULL OR NOT y) AND x = 1" => "(NOT y OR y IS NULL) AND x = 1 AND z = 1",
      "b = 2 OR a = 1 AND c = 3" => "(a = 1 AND c = 3) OR b = 2"
    }.each do |written, sorted|
      expect(predicate(written)).to eq(predicate(sorted)), written
      expect(predicate(written)).to eq(sorted), written
    end
  end

  it "makes candidates that differ only in condition order equal" do
    one = predicate("context_type = 'Course' AND workflow_state <> 'deleted' AND type = 'Assignment'")
    two = predicate("type = 'Assignment' AND context_type = 'Course' AND workflow_state <> 'deleted'")
    expect(one).to eq(two)
    expect(one).to start_with("context_type = 'Course' AND")
  end

  it "keeps a different grouping different" do
    expect(predicate("a = 1 AND (b = 2 OR c = 3)")).not_to eq(predicate("(a = 1 AND b = 2) OR c = 3"))
  end

  # Task 20261009-19: pg_query keeps c AND (b AND a) nested.
  it "flattens a nested AND inside an AND, and a nested OR inside an OR, before sorting" do
    expect(predicate("c = 3 AND (b = 2 AND a = 1)")).to eq("a = 1 AND b = 2 AND c = 3")
    expect(predicate("c = 3 OR (b = 2 OR a = 1)")).to eq("a = 1 OR b = 2 OR c = 3")
    expect(predicate("(c = 3 AND b = 2) AND a = 1")).to eq("a = 1 AND b = 2 AND c = 3")
    expect(predicate("x = 1 AND (c = 3 OR (b = 2 OR a = 1))")).to eq("(a = 1 OR b = 2 OR c = 3) AND x = 1")
  end
end
