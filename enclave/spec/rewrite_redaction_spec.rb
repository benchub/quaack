# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/rewrite_redaction"

# DESIGN.md's redact-rewrite: each literal in an operator's rewrite takes the
# placeholder of the original's literal in the same comparison.
RSpec.describe Quaack::Enclave::RewriteRedaction do
  let(:original) do
    "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id " \
      "WHERE o.status = $1 AND u.region = $2 AND o.total > $3 AND o.kind IN ($4, $5)"
  end
  # Sentinel literals: none of them may show up in any output or error.
  let(:sentinel) { "SENTINEL-7f3a" }

  def redact(sql, from: original) = described_class.redact(sql, from)

  def refusal(sql, from: original)
    redact(sql, from:)
    raise "not refused"
  rescue described_class::Refusal => e
    e
  end

  it "fills a rewrite that keeps the original's shape" do
    expect(redact("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id " \
                  "WHERE o.status = '#{sentinel}' AND u.region = 'y' AND o.total > 99 AND o.kind IN ('a', 'b')"))
      .to eq("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id " \
             "WHERE o.status = $1 AND u.region = $2 AND o.total > $3 AND o.kind IN ($4, $5)")
  end

  it "follows a predicate moved into a JOIN's ON" do
    expect(redact("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id AND u.region = 'y' " \
                  "WHERE o.status = '#{sentinel}'"))
      .to eq("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id AND u.region = $2 WHERE o.status = $1")
  end

  it "follows a predicate moved into a CTE, resolving an unqualified column to the scope's one table" do
    expect(redact("WITH r AS (SELECT id FROM users WHERE region = '#{sentinel}') " \
                  "SELECT o.id FROM orders o JOIN r ON r.id = o.user_id WHERE o.total > 5"))
      .to eq("WITH r AS (SELECT id FROM users WHERE region = $2) " \
             "SELECT o.id FROM orders o JOIN r ON r.id = o.user_id WHERE o.total > $3")
  end

  it "follows a predicate moved into an EXISTS, under another alias" do
    expect(redact("SELECT o.id FROM orders o WHERE o.status = 'x' AND EXISTS " \
                  "(SELECT us.id FROM users us WHERE us.id = o.user_id AND us.region = '#{sentinel}')"))
      .to eq("SELECT o.id FROM orders o WHERE o.status = $1 AND EXISTS " \
             "(SELECT us.id FROM users us WHERE us.id = o.user_id AND us.region = $2)")
  end

  it "matches IN-list members by slot, never by value" do
    expect(redact("SELECT o.id FROM orders o WHERE o.kind IN ('b', 'a')"))
      .to eq("SELECT o.id FROM orders o WHERE o.kind IN ($4, $5)")
  end

  it "keeps the constants the redactor keeps, such as a positional ORDER BY" do
    expect(redact("SELECT o.id FROM orders o WHERE o.total > 1 ORDER BY 1"))
      .to eq("SELECT o.id FROM orders o WHERE o.total > $3 ORDER BY 1")
  end

  it "refuses a literal in no original comparison, naming its position and not its value" do
    sql = "SELECT o.id FROM orders o WHERE o.total < '#{sentinel}'"
    error = refusal(sql)
    expect([error.rule, error.position]).to eq(["redact_rewrite_no_match", sql.index("'") + 1])
    expect(error.message).not_to include(sentinel)
    expect(error.inspect).not_to include(sentinel)
  end

  it "refuses a literal with no column context, such as EXISTS's SELECT 1 or a LIMIT" do
    sql = "SELECT o.id FROM orders o WHERE o.status = 'x' LIMIT 10"
    expect([refusal(sql).rule, refusal(sql).position]).to eq(["redact_rewrite_no_match", sql.index("10") + 1])
    exists = "SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM users u WHERE u.region = 'y')"
    expect(refusal(exists).position).to eq(exists.index("1 FROM") + 1)
  end

  it "refuses a literal that more than one original comparison matches" do
    from = "SELECT o.id FROM public.orders o WHERE o.status = $1 OR o.status = $2"
    sql = "SELECT o.id FROM orders o WHERE o.status = '#{sentinel}'"
    error = refusal(sql, from:)
    expect([error.rule, error.position]).to eq(["redact_rewrite_ambiguous", sql.index("'") + 1])
    expect(error.message).not_to include(sentinel)
  end

  it "takes a placeholder two equal comparisons share without calling it ambiguous" do
    from = "SELECT o.id FROM public.orders o WHERE o.status = $1 OR (o.total > $2 AND o.status = $1)"
    expect(redact("SELECT o.id FROM orders o WHERE o.status = 'x'", from:))
      .to eq("SELECT o.id FROM orders o WHERE o.status = $1")
  end

  it "tells two tables' same-named columns apart" do
    from = "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE o.id = $1 AND u.id = $2"
    expect(redact("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id WHERE u.id = 3 AND o.id = 4", from:))
      .to eq("SELECT o.id FROM orders o JOIN users u ON u.id = o.user_id WHERE u.id = $2 AND o.id = $1")
  end

  it "gives an unqualified column the one table of its own SELECT" do
    from = "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE o.id = $1 AND u.id = $2"
    expect(redact("WITH r AS (SELECT id FROM users WHERE id = 5) SELECT o.id FROM orders o JOIN r ON r.id = o.id",
                  from:))
      .to eq("WITH r AS (SELECT id FROM users WHERE id = $2) SELECT o.id FROM orders o JOIN r ON r.id = o.id")
  end

  it "doesn't take a comparison from outside a subquery the literal is in" do
    from = "SELECT o.id FROM public.orders o WHERE o.total > (SELECT $1)"
    sql = "SELECT o.id FROM orders o WHERE o.total > (SELECT 5)"
    expect(refusal(sql, from:).rule).to eq("redact_rewrite_no_match")
  end

  it "refuses a statement that already has placeholders of its own" do
    expect { redact("SELECT o.id FROM orders o WHERE o.status = $1") }
      .to raise_error(Quaack::Enclave::Redaction::Error, "query_has_parameters")
  end
end

RSpec.describe Quaack::Enclave::RewriteRedaction, ".checked" do
  it "refuses output that still holds a literal, and passes one that holds only placeholders" do
    expect { described_class.checked("SELECT o.id FROM orders o WHERE o.status = 'SENTINEL-7f3a'") }
      .to raise_error(described_class::Error) { expect(it.message).not_to include("SENTINEL") }
    expect(described_class.checked("SELECT o.id FROM orders o WHERE o.status = $1 ORDER BY 1"))
      .to eq("SELECT o.id FROM orders o WHERE o.status = $1 ORDER BY 1")
  end
end
