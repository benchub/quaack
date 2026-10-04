# frozen_string_literal: true

require_relative "support/index_search_run"

# DESIGN.md's clock-anchor: a rewrite candidate reads the anchored clock, as the original
# does, so an equivalent candidate matches it in rewrite-test and result-comparison even when the
# anchor is far from the real clock.
RSpec.describe "clock anchoring in rewrite candidates, against a real server" do
  include_context "an index search run"

  def run(step, stdin: nil) = quaacks.run(step, "--run", store.run_id, stdin:, env: libpq_env)

  # An anchor years before every row's created_at.
  def pin_anchor_far_back
    conn = production.connect
    conn.exec("CREATE OR REPLACE FUNCTION quaack.clock_anchor() RETURNS pg_catalog.timestamptz " \
              "LANGUAGE sql IMMUTABLE AS $$SELECT '2000-01-01 00:00:00+00'::pg_catalog.timestamptz$$")
  ensure
    conn&.close
  end

  def check(candidate)
    prepare
    pin_anchor_far_back
    rewrite = { "sql" => candidate, "transformation" => "t", "assumptions" => [] }
    checked = run("rewrite-check", stdin: JSON.generate("rewrites" => [rewrite]))
    expect(checked.stdout.lines.first).to include('"rewrite":"rewrite_1"')
  end

  def compare
    stored.write("baseline", "timeout_ms" => 5_000)
    stored.write("candidate_runs", "candidates" => { "rewrite_1" => {} })
    run("result-comparison")
    stored.read("result_comparison")["verdicts"]["rewrite_1"]
  end

  pass = %w[slow worst_case typical].to_h { [it, { "result" => "pass", "rule" => nil }] }

  context "with now()" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held' " \
        "AND o.created_at < now()"
    end

    it "passes result-comparison for an equivalent candidate that calls now()" do
      check("SELECT o.note, o.status FROM public.orders o WHERE o.created_at < now() AND o.status = $2 AND o.note = $1")
      expect(compare).to eq(pass)
    end

    it "keeps the candidate's now() in sql, for the payloads and report, and anchors only anchored_sql" do
      check("SELECT o.note, o.status FROM public.orders o WHERE o.created_at < now() AND o.status = $2 AND o.note = $1")
      held = stored.read("rewrite_1")
      expect(held["sql"]).to include("now()")
      expect(held["anchored_sql"]).to include("quaack.clock_anchor()")
      expect(held["anchored_sql"]).not_to include("now()")
    end

    it "rejects a candidate that already calls quaack.clock_anchor()" do
      prepare
      rewrite = { "sql" => "SELECT o.note, o.status FROM public.orders o " \
                           "WHERE o.created_at < quaack.clock_anchor() AND o.status = $2 AND o.note = $1",
                  "transformation" => "t", "assumptions" => [] }
      checked = run("rewrite-check", stdin: JSON.generate("rewrites" => [rewrite]))
      expect(JSON.parse(checked.stdout.lines.first).slice("outcome", "rule"))
        .to eq("outcome" => "rejected", "rule" => "clock_anchor_in_query")
    end
  end

  context "with a 'now' literal compared with a timestamptz column" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held' " \
        "AND o.created_at < 'now'"
    end

    it "passes result-comparison for an equivalent candidate that keeps the placeholder" do
      check("SELECT o.note, o.status FROM public.orders o WHERE o.created_at < $3 AND o.status = $2 AND o.note = $1")
      expect(compare).to eq(pass)
    end
  end
end
