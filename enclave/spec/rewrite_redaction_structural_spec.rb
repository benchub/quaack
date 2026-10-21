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

  it "refuses a LIMIT the rewrite adds inside a LATERAL subquery, not taking the top LIMIT's" do
    original = "SELECT o.id FROM orders o WHERE o.s = 'a' LIMIT 50"
    rewrite = "SELECT o.id, l.v FROM orders o CROSS JOIN LATERAL (SELECT i.v FROM items i WHERE i.oid = o.id " \
              "ORDER BY i.v LIMIT 1) l WHERE o.s = 'a' LIMIT 50"
    error = refusal(rewrite, original)
    expect([error.rule, error.position]).to eq(["redact_rewrite_no_match", rewrite.index("1)") + 1])
  end

  it "matches a nested LIMIT only to the original's LIMIT at the same nesting" do
    original = "SELECT o.id, l.v FROM orders o CROSS JOIN LATERAL (SELECT i.v FROM items i WHERE i.oid = o.id " \
               "ORDER BY i.v LIMIT 1) l WHERE o.s = 'a' LIMIT 50"
    rewrite = "SELECT o.id, l.v FROM orders o CROSS JOIN LATERAL (SELECT i.v FROM items i WHERE i.oid = o.id " \
              "ORDER BY i.v DESC LIMIT 1) l WHERE o.s = 'a' LIMIT 50"
    out = redact(rewrite, original)
    expect(out).to include("DESC LIMIT $1)").and end_with("LIMIT $3")
  end

  it "tells a CTE's LIMIT from a top-level one with an equal value" do
    original = "WITH r AS (SELECT o.id FROM orders o LIMIT 10) SELECT r.id FROM r LIMIT 10"
    out = redact("WITH r AS (SELECT o.id FROM orders o ORDER BY o.id LIMIT 10) SELECT r.id FROM r LIMIT 10", original)
    expect(out).to include("o.id LIMIT $1)").and end_with("LIMIT $2")
    cte_only = "WITH r AS (SELECT o.id FROM orders o LIMIT 10) SELECT r.id FROM r"
    error = refusal("SELECT o.id FROM orders o LIMIT 10", cte_only)
    expect(error.rule).to eq("redact_rewrite_no_match")
  end

  it "refuses an EXISTS's SELECT 2 nested one level deeper than the original's" do
    original = "SELECT o.id FROM orders o WHERE EXISTS (SELECT 2 FROM users u WHERE u.id = o.user_id)"
    rewrite = "SELECT o.id FROM orders o WHERE o.id IN (SELECT i.oid FROM items i " \
              "WHERE EXISTS (SELECT 2 FROM users u WHERE u.id = i.uid))"
    expect(refusal(rewrite, original).rule).to eq("redact_rewrite_no_match")
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
  # 20261020-7: the user's rewrite turns an IN over a UNION ALL into an
  # EXISTS (SELECT 1 ...), and the original has no 1 to take.
  describe "an EXISTS's SELECT 1 the original has no placeholder for" do
    let(:union) do
      "SELECT o.id FROM orders o WHERE o.status = '#{sentinel}' AND o.id IN " \
        "((SELECT i.oid FROM items i WHERE i.kind = 'a') UNION ALL (SELECT i.oid FROM items i WHERE i.kind = 'b'))"
    end

    def exists(target)
      "SELECT o.id FROM orders o WHERE o.status = '#{sentinel}' AND EXISTS " \
        "(SELECT #{target} FROM items i WHERE i.oid = o.id AND i.kind = 'a')"
    end

    it "keeps the integer 1 as written" do
      out = redact(exists("1"), union)
      expect(out).to eq("SELECT o.id FROM orders o WHERE o.status = $1 AND EXISTS " \
                        "(SELECT 1 FROM items i WHERE i.oid = o.id AND i.kind = $2)")
      expect(out).not_to include(sentinel)
    end

    it "still refuses any other constant there" do
      ["2", "'x'", "1.0", "'1'", "-1"].each do |target|
        sql = exists(target)
        error = refusal(sql, union)
        expect([target, error.rule, error.position])
          .to eq([target, "redact_rewrite_no_match", sql.index("SELECT #{target}") + 8])
      end
    end

    it "refuses a 1 in a scalar subquery's or the top SELECT's target list" do
      scalar = "SELECT o.id, (SELECT 1 FROM items i WHERE i.oid = o.id) FROM orders o WHERE o.status = 'a'"
      expect(refusal(scalar, union).rule).to eq("redact_rewrite_no_match")
      expect(refusal("SELECT 1 FROM orders o WHERE o.status = 'a'", union).rule).to eq("redact_rewrite_no_match")
    end

    it "keeps a sentinel in that position out of the output and the refusal" do
      sql = exists("'#{sentinel}'")
      error = refusal(sql, union)
      expect(error.rule).to eq("redact_rewrite_no_match")
      expect(error.message).not_to include(sentinel)
    end

    it "still takes the original's placeholder when one matches" do
      original = "SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM items i WHERE i.oid = o.id)"
      expect(redact("SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM items i WHERE i.oid = o.id)", original))
        .to include("SELECT $1 FROM items")
    end

    it "has an output check that still catches a 1 left anywhere else" do
      expect { described_class.checked("SELECT o.id FROM orders o WHERE o.n = 1") }
        .to raise_error(described_class::Error)
      expect(described_class.checked("SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM items i)"))
        .to eq("SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM items i)")
    end
  end
end
