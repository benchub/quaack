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
end
