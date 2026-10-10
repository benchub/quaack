# frozen_string_literal: true

require "quaack/driver/winner_summary"

# The facts the winner summary gets about duplicated conditions
# (20261010-37): conditions the original repeats across the arms of an OR
# or the branches of a UNION, as shapes with $n and no table qualifier, and
# how often each appears in the original and in the winner. Every query
# here is synthetic.
RSpec.describe Quaack::Driver::WinnerSummary::Repeats do
  def of(original, winner) = described_class.of(original, winner)

  it "finds a condition repeated across OR arms, and counts it in the winner" do
    original = "SELECT o.id FROM public.orders o WHERE (o.tenant_id = $1 AND o.state = $2) " \
               "OR (o.tenant_id = $1 AND o.kind = $3)"
    winner = "SELECT o.id FROM public.orders o WHERE o.tenant_id = $1 AND (o.state = $2 OR o.kind = $3)"
    expect(of(original, winner)).to eq(
      [{ "condition" => "tenant_id = $1", "repeated_across" => "OR arms", "in_original" => 2, "in_winner" => 1 }]
    )
  end

  it "finds a condition repeated across UNION branches, counting a filter outside the UNION as a branch" do
    original = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
               "SELECT id, state FROM public.archived WHERE state = $1) s WHERE s.state = $1"
    winner = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
             "SELECT id, state FROM public.archived WHERE state = $1) s"
    expect(of(original, winner)).to eq(
      [{ "condition" => "state = $1", "repeated_across" => "UNION branches", "in_original" => 3, "in_winner" => 2 }]
    )
  end

  it "finds a filter outside a UNION that one branch already applies" do
    original = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
               "SELECT id, state FROM public.archived WHERE kind = $2) s WHERE s.state = $1"
    expect(of(original, original).map { it.values_at("condition", "repeated_across") })
      .to eq([["state = $1", "UNION branches"]])
  end

  it "finds repeats inside a subquery, as an existence_in_flip original has them" do
    original = "SELECT 1 FROM public.orders WHERE user_id IN (SELECT id FROM public.users u WHERE " \
               "(u.region = $1 AND u.active) OR (u.region = $1 AND u.vip)) LIMIT 1"
    winner = "SELECT 1 FROM public.users u WHERE u.region = $1 AND (u.active OR u.vip) AND EXISTS " \
             "(SELECT 1 FROM public.orders o WHERE o.user_id = u.id) LIMIT 1"
    expect(of(original, winner).map { it.values_at("condition", "in_original", "in_winner") })
      .to eq([["region = $1", 2, 1]])
  end

  it "reports nothing when no condition repeats" do
    winner = "SELECT 1 FROM t WHERE a = $1 UNION SELECT 1 FROM t WHERE b = $2"
    expect(of("SELECT 1 FROM t WHERE a = $1 OR b = $2", winner)).to eq([])
  end

  it "reports nothing, and doesn't raise, when either SQL doesn't parse or is missing" do
    expect(of("SELECT FROM WHERE (", "SELECT 1")).to eq([])
    expect(of("SELECT 1 FROM t WHERE (a = $1 AND b) OR (a = $1 AND c)", nil)).to eq([])
  end

  it "leaves out a condition that holds a literal, so no value goes in" do
    original = "SELECT 1 FROM t WHERE (a = 'secret-sentinel' AND b) OR (a = 'secret-sentinel' AND c)"
    expect(of(original, "SELECT 1 FROM t")).to eq([])
  end

  it "keeps the list short" do
    arm = (1..20).map { "c#{it} = $#{it}" }.join(" AND ")
    expect(of("SELECT 1 FROM t WHERE (#{arm} AND x) OR (#{arm} AND y)", "SELECT 1").size)
      .to eq(described_class::MOST)
  end
end
