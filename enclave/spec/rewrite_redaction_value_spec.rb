# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/rewrite_redaction"

# 20261020-1: when more than one original placeholder matches a literal's
# comparison, the run's placeholder map breaks the tie by value. Built on a
# synthetic copy of the shape of the user's first real run.
RSpec.describe Quaack::Enclave::RewriteRedaction, "value tie-break" do
  let(:sentinel) { "SENTINEL-tie-5d2e" }
  let(:other_sentinel) { "SENTINEL-other-9b41" }
  let(:contexts) { (7001..7021).to_a }
  let(:assignments) { (88_001..88_012).to_a }

  # The query with literals, as the run's original was written.
  def query(context_ids: contexts, assignment_ids: assignments, join_state: sentinel, where_state: sentinel)
    "SELECT s.id FROM public.submissions s JOIN public.assignments a ON a.id = s.assignment_id " \
      "AND s.workflow_state <> '#{join_state}' " \
      "WHERE s.workflow_state != '#{where_state}' AND a.context_id IN (#{context_ids.join(", ")}) " \
      "AND a.id IN (#{assignment_ids.join(", ")}) AND s.workflow_state != '#{sentinel}' " \
      "AND s.submitted_at BETWEEN '2031-01-01' AND '2031-02-01' " \
      "AND EXISTS (SELECT u.id FROM public.users u WHERE u.id = s.user_id AND u.workflow_state = 'active')"
  end

  # [redacted original, placeholder map], as redact makes them.
  def run_for(sql)
    redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(sql))
    [redacted.sql, redacted.placeholder_map]
  end

  def redact(rewrite, original = query)
    described_class.redact(rewrite, *run_for(original))
  end

  def refusal(rewrite, original = query)
    redact(rewrite, original)
    raise "not refused"
  rescue described_class::Refusal => e
    e
  end

  # The user's rewrite: the same query, the join turned into an EXISTS.
  def rewrite(context_ids: contexts, assignment_ids: assignments, state: sentinel)
    "SELECT s.id FROM submissions s WHERE EXISTS (SELECT a.id FROM assignments a WHERE a.id = s.assignment_id " \
      "AND a.context_id IN (#{context_ids.join(", ")}) AND a.id IN (#{assignment_ids.join(", ")})) " \
      "AND s.workflow_state <> '#{state}' AND s.workflow_state != '#{state}' " \
      "AND s.submitted_at BETWEEN '2031-01-01' AND '2031-02-01' " \
      "AND EXISTS (SELECT u.id FROM users u WHERE u.id = s.user_id AND u.workflow_state = 'active')"
  end

  it "gives three equal comparisons with equal values the lowest placeholder" do
    out = redact(rewrite)
    expect(out).to include("s.workflow_state <> $1 AND s.workflow_state <> $1")
    expect(out).to include("a.context_id IN (#{(3..23).map { "$#{it}" }.join(", ")})")
    expect(out).to include("a.id IN (#{(24..35).map { "$#{it}" }.join(", ")})")
    expect(out).to include("BETWEEN $37 AND $38").and include("u.workflow_state = $39")
    expect(out).not_to include(sentinel)
  end

  it "picks the one candidate whose original literal equals the rewrite's" do
    original = query(join_state: other_sentinel)
    expect(redact(rewrite(state: other_sentinel),
                  original)).to include("s.workflow_state <> $1 AND s.workflow_state <> $1")
    expect(redact(rewrite, original)).to include("s.workflow_state <> $2 AND s.workflow_state <> $2")
  end

  it "compares the literal's type as well as its text" do
    original = "SELECT s.id FROM public.submissions s WHERE s.score <> '5' AND s.score <> 5"
    expect(redact("SELECT s.id FROM submissions s WHERE s.score <> 5", original))
      .to eq("SELECT s.id FROM submissions s WHERE s.score <> $2")
  end

  it "refuses when no candidate holds the rewrite's value, naming the candidates and never a value" do
    sql = rewrite(state: "changed-#{sentinel}")
    error = refusal(sql)
    expect([error.rule, error.position, error.candidates])
      .to eq(["redact_rewrite_ambiguous", sql.index("'changed") + 1, [1, 2, 36]])
    expect([error.message, error.inspect].join).not_to include(sentinel)
  end

  it "never matches by value across comparisons whose keys differ" do
    original = "SELECT s.id FROM public.submissions s WHERE s.workflow_state = '#{sentinel}'"
    expect(refusal("SELECT s.id FROM submissions s WHERE s.workflow_state <> '#{sentinel}'", original).rule)
      .to eq("redact_rewrite_no_match")
  end

  it "refuses an IN list whose length differs from the original's, at its first member" do
    longer = rewrite(context_ids: contexts + [7099])
    shorter = rewrite(context_ids: contexts.first(20))
    [longer, shorter].each do |sql|
      error = refusal(sql)
      expect([error.rule, error.position]).to eq(["redact_rewrite_no_match", sql.index("7001") + 1])
    end
  end

  it "would see the sentinel in the rewrite it was given" do
    expect(rewrite).to include(sentinel)
  end
end
