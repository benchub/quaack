# frozen_string_literal: true

require "quaack/enclave/deparse"

# The loosest operator Parentheses finds at each end of an expression. Most
# of what it finds shows only in how Deparse writes SQL, which
# deparse_spec.rb covers. These are the ends the deparser's own parentheses
# hide there.
RSpec.describe Quaack::Enclave::Deparse::Parentheses do
  def ends(sql)
    select = PgQuery.parse("SELECT #{sql}").tree.stmts[0].stmt.select_stmt
    described_class.visit(select.target_list[0].res_target.val)
  end

  def ends_of(left, right, b_expr: false) = described_class::Ends.new(left:, right:, b_expr:)

  it "finds AND at both ends of an AND" do
    expect(ends("a AND b")).to eq(ends_of(described_class::AND, described_class::AND))
  end

  it "finds OR at both ends of an OR" do
    expect(ends("a OR b")).to eq(ends_of(described_class::OR, described_class::OR))
  end

  # A leading sign is closed on its left, and its right end is its
  # operand's when that's looser.
  it "finds the NOT at the right end of a sign in front of NOT" do
    expect(ends("- (NOT a)")).to eq(ends_of(described_class::CLOSED, described_class::NOT))
  end

  # An infix operator is a b_expr only if it's one that can be, and both
  # its operands are.
  it "finds LIKE isn't a b_expr, though both its operands are" do
    expect(ends("a LIKE b")).to eq(ends_of(described_class::LIKE, described_class::LIKE))
  end

  it "finds + isn't a b_expr when its left operand isn't" do
    expect(ends("(a IS NULL) + b")).to eq(ends_of(described_class::IS, described_class::ADD))
  end

  it "finds + isn't a b_expr when its right operand isn't" do
    expect(ends("a + (NOT b)")).to eq(ends_of(described_class::ADD, described_class::NOT))
  end

  it "finds + is a b_expr when both its operands are" do
    expect(ends("a + b")).to eq(ends_of(described_class::ADD, described_class::ADD, b_expr: true))
  end

  # ~~ ANY (SELECT ...) is written LIKE ANY, which binds at LIKE.
  it "finds LIKE at the left end of ~~ ANY over a subquery" do
    expect(ends("a ~~ ANY (SELECT 'x')")).to eq(ends_of(described_class::LIKE, described_class::CLOSED))
  end
end
