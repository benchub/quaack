# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks index-feedback` (DESIGN.md 5a-6): the 5a-4 results for the LLM's
# own candidates, and which fell short, after a real index-search.
RSpec.describe "quaacks index-feedback, against a real server" do
  include_context "an index search run"

  def index_feedback(*extra) = quaacks.run("index-feedback", "--run", store.run_id, *extra)
  def error_line(rule) = %({"type":"error","step":"index-feedback","rule":"#{rule}"}\n)

  def column(name, expression = nil)
    { "name" => name, "expression" => expression, "direction" => "asc", "nulls" => "last", "opclass" => nil,
      "collation" => nil }
  end

  def candidate(key, predicate: nil, sources: ["llm"])
    { "table" => { "schema" => "public", "name" => "orders" }, "key" => key, "include" => [],
      "access_method" => "btree", "predicate" => predicate, "unique" => false, "sources" => sources }
  end

  def plans(entry, used:, cost:)
    entry["baseline"].to_h { |set, plan| [set, { "used" => used, "total_cost" => cost, "plan" => plan["plan"] }] }
  end

  # Replaces the stored results with one used mechanical candidate on
  # (status), and plants LLM results: one the planner never used, with the
  # sentinel in its predicate and key expression; one on (status, total)
  # that costs the same as the mechanical one; and one that beats it.
  def plant
    entry = stored.read("index_search_original")
    mechanical = { "candidate" => candidate([column("status")], sources: ["parse"]), "partial_constant_only" => false,
                   "size" => 8192, "refusal" => nil, "plans" => plans(entry, used: true, cost: 50.0) }
    stored.write("index_search_original",
                 entry.merge("results" => [mechanical], "llm_results" => llm_results(entry, mechanical)))
    entry
  end

  def llm_results(entry, mechanical)
    [
      { "candidate" => candidate([column(nil, "coalesce(note, '#{sentinels.text}')")],
                                 predicate: "status = 'held' AND note = '#{sentinels.text}'"),
        "partial_constant_only" => true, "size" => 8192, "refusal" => nil,
        "plans" => plans(entry, used: false, cost: 100.0) },
      mechanical.merge("candidate" => candidate([column("status"), column("total")]), "size" => 16_384),
      mechanical.merge("candidate" => candidate([column("status"), column("note")]),
                       "plans" => plans(entry, used: true, cost: 10.0))
    ]
  end

  def feedback(outcome)
    lines = outcome.stdout.lines
    expect([lines.size, lines.last, outcome.stderr, outcome.status.exitstatus])
      .to eq([2, %({"type":"done"}\n), "", 0])
    JSON.parse(lines.first)
  end

  it "sends each LLM candidate's redacted DDL, 5a-4 results, and shortfall, and asks for a revision" do
    prepare
    index_search
    entry = plant

    outcome = index_feedback
    sent = feedback(outcome)

    expect_no_leaks(sentinels, outcome)
    expect(sent.keys).to eq(%w[type revise refined baseline candidates])
    expect(sent.slice("type", "revise", "refined")).to eq("type" => "index_feedback", "revise" => true,
                                                          "refined" => false)
    expect(sent["baseline"]).to eq(entry["baseline"].transform_values { it["total_cost"] })
    expect(sent["candidates"].map { it.slice("ddl", "shortfall", "beaten_by") }).to eq(
      [{ "ddl" => "CREATE INDEX ON public.orders USING btree (COALESCE(note, ?)) " \
                  "WHERE status = 'held' AND note = ?", "shortfall" => "unused", "beaten_by" => nil },
       { "ddl" => "CREATE INDEX ON public.orders USING btree (status, total)", "shortfall" => "beaten",
         "beaten_by" => "CREATE INDEX ON public.orders USING btree (status)" },
       { "ddl" => "CREATE INDEX ON public.orders USING btree (status, note)", "shortfall" => nil,
         "beaten_by" => nil }]
    )
    first = sent["candidates"].first
    expect(first.slice("partial_constant_only", "size", "refusal")).to eq(
      "partial_constant_only" => true, "size" => 8192, "refusal" => nil
    )
    expect(first["plans"]).to eq(plans(entry, used: false, cost: 100.0))
    # The check itself catches the sentinel where it is held.
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(stored.read("index_search_original")))).not_to eq([])
  end

  it "doesn't ask for a revision when every LLM candidate held up, and says when the round already ran" do
    prepare
    index_search
    plant
    stored.write("index_search_original", stored.read("index_search_original").then do |held|
      held.merge("llm_results" => held["llm_results"].last(1), "refined" => true)
    end)

    sent = feedback(index_feedback)

    expect(sent.slice("revise", "refined")).to eq("revise" => false, "refined" => true)
    expect(sent["candidates"].map { it["shortfall"] }).to eq([nil])
  end

  it "refuses an unknown search, and a run with no index search" do
    prepare

    expect(index_feedback.stdout).to eq(error_line("index_feedback_no_index_search"))
    expect(index_feedback("--search", "rewrite_1").stdout).to eq(error_line("index_feedback_unknown_search"))
  end
end
