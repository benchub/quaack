# frozen_string_literal: true

require "quaack/enclave/steps/winner_times"

# Task 20261016-14: two plans are the same steps only if each step has the
# same type, relation, index, and depth, in the same order.
RSpec.describe Quaack::Enclave::Steps::WinnerTimes do
  def step(node, depth, relation: nil, index: nil)
    { "node" => node, "relation" => relation, "index" => index, "depth" => depth, "est_rows" => depth + 1 }
  end

  let(:measured) do
    [step("Nested Loop", 0), step("Seq Scan", 1, relation: "public.a"), step("Seq Scan", 2, relation: "public.a")]
  end

  it "takes steps with other row counts for the same steps" do
    expect(described_class.same?(measured, measured.map { it.merge("est_rows" => 9) })).to be(true)
  end

  it "takes the same types in the same order at other depths for other steps" do
    moved = measured.each_with_index.map { |s, i| s.merge("depth" => [0, 1, 1][i]) }
    expect(described_class.same?(measured, moved)).to be(false)
  end
end
