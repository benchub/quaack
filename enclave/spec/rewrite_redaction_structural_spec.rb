# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/rewrite_redaction"

# 20261019-4: a literal with no column comparison takes the placeholder of
# the original's literal in the same clause: an EXISTS's (or other
# SubLink's) target list, a LIMIT count, or an OFFSET.
RSpec.describe Quaack::Enclave::RewriteRedaction, "structural keys" do
  let(:sentinel) { "SENTINEL-struct-3c8e" }

  def run_for(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    [redacted.sql, redacted.placeholder_map]
  end

  def redact(rewrite, original) = described_class.redact(rewrite, *run_for(original))

  def refusal(rewrite, original)
    redact(rewrite, original)
    raise "not refused"
  rescue described_class::Refusal => e
    e
  end

  # A synthetic copy of the user's run: the 1 of EXISTS (SELECT 1 ...) is numbered.
  let(:original) do
    "SELECT s.id FROM public.submissions s JOIN public.assignments a ON a.id = s.assignment_id " \
      "WHERE s.workflow_state <> '#{sentinel}' AND a.context_id IN (7001, 7002) " \
      "AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = s.user_id AND u.workflow_state = 'active')"
  end

  it "gives EXISTS's SELECT 1 the original's placeholder for it" do
    expect(run_for(original).first).to include("EXISTS (SELECT $4 FROM")
    rewrite = "SELECT s.id FROM submissions s WHERE EXISTS (SELECT 1 FROM assignments a " \
              "WHERE a.id = s.assignment_id AND a.context_id IN (7001, 7002)) AND s.workflow_state <> '#{sentinel}' " \
              "AND EXISTS (SELECT 1 FROM users u WHERE u.id = s.user_id AND u.workflow_state = 'active')"
    out = redact(rewrite, original)
    expect(out).to include("EXISTS (SELECT $4 FROM assignments").and include("EXISTS (SELECT $4 FROM users")
    expect(out).to include("u.workflow_state = $5").and include("IN ($2, $3)")
    expect(out).not_to include(sentinel)
  end

  it "fills an ORM's LIMIT and OFFSET from the original's" do
    orm = "SELECT \"orders\".* FROM \"orders\" WHERE \"orders\".\"status\" = '#{sentinel}' " \
          "ORDER BY \"orders\".\"id\" DESC LIMIT 25 OFFSET 50"
    rewrite = "SELECT o.* FROM orders o WHERE o.status = '#{sentinel}' ORDER BY o.id DESC LIMIT 25 OFFSET 50"
    out = redact(rewrite, orm)
    expect(out).to end_with("LIMIT $2 OFFSET $3")
    expect(out).to include("o.status = $1")
    expect(out).not_to include(sentinel)
  end

  it "tells LIMIT from OFFSET when they hold equal values" do
    out = redact("SELECT o.id FROM orders o LIMIT 10 OFFSET 10", "SELECT o.id FROM orders o LIMIT 10 OFFSET 10")
    expect(out).to end_with("LIMIT $1 OFFSET $2")
  end

  it "breaks a tie between two EXISTS by value, and refuses one values can't break, naming candidates" do
    two = "SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM users u WHERE u.id = o.user_id) " \
          "AND EXISTS (SELECT 2 FROM items i WHERE i.order_id = o.id)"
    rewrite = "SELECT o.id FROM orders o WHERE EXISTS (SELECT 2 FROM items i WHERE i.order_id = o.id)"
    expect(redact(rewrite, two)).to include("SELECT $2 FROM items")
    error = refusal("SELECT o.id FROM orders o WHERE EXISTS (SELECT 3 FROM items i WHERE i.order_id = o.id)", two)
    expect([error.rule, error.candidates]).to eq(["redact_rewrite_ambiguous", [1, 2]])
  end

  it "keeps a sentinel out of a refusal for a LIMIT the original lacks" do
    sql = "SELECT o.id FROM orders o WHERE o.status = '#{sentinel}' LIMIT 4242"
    error = refusal(sql, "SELECT o.id FROM orders o WHERE o.status = '#{sentinel}'")
    expect([error.rule, error.position]).to eq(["redact_rewrite_no_match", sql.index("4242") + 1])
    expect(error.message).not_to include(sentinel)
    expect(error.message).not_to include("4242")
  end

  it "has a sentinel check that catches a planted sentinel" do
    expect { described_class.checked("SELECT o.id FROM orders o LIMIT 5 OFFSET '#{sentinel}'") }
      .to raise_error(described_class::Error) { expect(it.message).not_to include(sentinel) }
  end
end
