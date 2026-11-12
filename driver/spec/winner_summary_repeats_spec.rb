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
               "OR (o.tenant_id = $3 AND o.kind = $4)"
    winner = "SELECT o.id FROM public.orders o WHERE o.tenant_id = $1 AND (o.state = $2 OR o.kind = $3)"
    expect(of(original, winner)).to eq(
      [{ "condition" => "tenant_id = $", "repeated_across" => "OR arms", "in_original" => 2, "in_winner" => 1 }]
    )
  end

  it "finds a condition repeated across UNION branches, counting a filter outside the UNION as a branch" do
    original = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
               "SELECT id, state FROM public.archived WHERE state = $2) s WHERE s.state = $3"
    winner = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
             "SELECT id, state FROM public.archived WHERE state = $2) s"
    expect(of(original, winner)).to eq(
      [{ "condition" => "state = $", "repeated_across" => "UNION branches", "in_original" => 3, "in_winner" => 2 }]
    )
  end

  it "finds a filter outside a UNION that one branch already applies" do
    original = "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
               "SELECT id, state FROM public.archived WHERE kind = $2) s WHERE s.state = $3"
    expect(of(original, original).map { it.values_at("condition", "repeated_across") })
      .to eq([["state = $", "UNION branches"]])
  end

  it "finds repeats inside a subquery, as an existence_in_flip original has them" do
    original = "SELECT 1 FROM public.orders WHERE user_id IN (SELECT id FROM public.users u WHERE " \
               "(u.region = $1 AND u.active) OR (u.region = $2 AND u.vip)) LIMIT $3"
    winner = "SELECT 1 FROM public.users u WHERE u.region = $1 AND (u.active OR u.vip) AND EXISTS " \
             "(SELECT 1 FROM public.orders o WHERE o.user_id = u.id) LIMIT 1"
    expect(of(original, winner).map { it.values_at("condition", "in_original", "in_winner") })
      .to eq([["users.region = $", 2, 1]])
  end

  it "reports nothing when no condition repeats" do
    winner = "SELECT 1 FROM t WHERE a = $1 UNION SELECT 1 FROM t WHERE b = $2"
    expect(of("SELECT 1 FROM t WHERE a = $1 OR b = $2", winner)).to eq([])
  end

  it "reports nothing, and doesn't raise, when either SQL doesn't parse or is missing" do
    expect(of("SELECT FROM WHERE (", "SELECT 1")).to eq([])
    expect(of("SELECT 1 FROM t WHERE (a = $1 AND b) OR (a = $2 AND c)", nil)).to eq([])
  end

  it "keeps the qualifiers of a repeated equality between two columns" do
    original = "SELECT 1 FROM public.a a JOIN public.b b ON true WHERE (a.id = b.a_id AND a.x = $1) OR " \
               "(a.id = b.a_id AND b.y = $2)"
    expect(of(original, original).map { it["condition"] }).to eq(["a.id = b.a_id"])
  end

  it "leaves out a condition that holds a literal, so no value goes in" do
    original = "SELECT 1 FROM t WHERE (a = 'secret-sentinel' AND b) OR (a = 'secret-sentinel' AND c)"
    expect(of(original, "SELECT 1 FROM t")).to eq([])
  end

  it "keeps the qualifier when the query reads more than one table, so two tables' columns stay apart" do
    original = "SELECT 1 FROM public.a a JOIN public.b b ON a.id = b.a_id WHERE (a.x = $1 AND a.y) OR " \
               "(b.x = $2 AND b.z)"
    expect(of(original, original)).to eq([])
  end

  it "gives a condition one shape in both queries when the winner drops a join" do
    arms = "(o.state = $1 AND o.a) OR (o.state = $2 AND o.b)"
    original = "SELECT o.id FROM public.orders o JOIN public.users u ON o.user_id = u.id WHERE #{arms}"
    expect(of(original, "SELECT o.id FROM public.orders o WHERE #{arms}"))
      .to eq([{ "condition" => "orders.state = $", "repeated_across" => "OR arms", "in_original" => 2,
                "in_winner" => 2 }])
  end

  it "gives a condition one shape in both queries when the winner adds a table" do
    arms = "(o.state = $1 AND o.a) OR (o.state = $2 AND o.b)"
    winner = "SELECT o.id FROM public.orders o WHERE (#{arms}) AND " \
             "EXISTS (SELECT 1 FROM public.users u WHERE u.id = o.user_id)"
    expect(of("SELECT o.id FROM public.orders o WHERE #{arms}", winner)
      .map { it.values_at("in_original", "in_winner") }).to eq([[2, 2]])
  end

  it "gives a condition one shape when one query names the table and the other an alias for it" do
    original = "SELECT 1 FROM public.orders JOIN public.users u ON orders.user_id = u.id WHERE " \
               "(orders.a AND orders.b = $1) OR (orders.a AND orders.c = $2)"
    winner = "SELECT 1 FROM public.orders o JOIN public.users u ON o.user_id = u.id WHERE " \
             "(o.a AND o.b = $1) OR (o.a AND o.c = $2)"
    expect(of(original, winner))
      .to eq([{ "condition" => "orders.a", "repeated_across" => "OR arms", "in_original" => 2, "in_winner" => 2 }])
  end

  it "keeps an alias that names two tables, so it isn't written as either one" do
    original = "SELECT 1 FROM public.orders x JOIN public.items i ON i.id = x.item_id WHERE (x.a AND x.b) OR " \
               "(x.a AND x.c) UNION ALL SELECT 1 FROM public.users x"
    expect(of(original, original).map { it["condition"] }).to eq(["x.a"])
  end

  it "keeps a self-join's aliases apart" do
    original = "SELECT 1 FROM public.t a JOIN public.t b ON a.id = b.id WHERE (a.x AND a.y) OR (b.x AND b.z)"
    expect(of(original, original)).to eq([])
  end

  it "doesn't count a condition twice within one OR arm" do
    expect(of("SELECT 1 FROM t WHERE (a = $1 AND a = $2) OR b = $3", "SELECT 1 FROM t")).to eq([])
  end

  it "keeps the list short" do
    arm = (1..20).map { "c#{it} = $#{it}" }.join(" AND ")
    expect(of("SELECT 1 FROM t WHERE (#{arm} AND x) OR (#{arm} AND y)", "SELECT 1").size)
      .to eq(described_class::MOST)
  end
end
