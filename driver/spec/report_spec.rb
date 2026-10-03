# frozen_string_literal: true

require "quaack/driver/report"

RSpec.describe Quaack::Driver::Report do
  def m(blocks, hit, stable: true)
    { "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "stable" => stable, "timed_out" => false }
  end

  let(:payload) do
    { "type" => "report",
      "top" => [{ "label" => "rewrite_1:none", "slow_blocks" => 300, "total_blocks_sum" => 400, "footprint" => 0 },
                { "label" => "original:top:1", "slow_blocks" => 400, "total_blocks_sum" => 590,
                  "footprint" => 8192 }],
      "excluded" => { "rewrite_1:top:1" => "not_better" }, "infinite_sets" => [],
      "original_sql" => "SELECT id FROM t WHERE created_at > now() - $1",
      "original_measurements" => { "slow" => m(1000, 100), "typical" => m(200, 150) },
      "labels" => [
        { "label" => "original:top:1", "search" => "original", "indexes" => ["quaack_a"], "timed_out" => false,
          "measurements" => { "slow" => m(400, 300), "typical" => m(190, 190) },
          "verdicts" => { "slow" => "better", "typical" => "no_worse" } },
        { "label" => "rewrite_1:none", "search" => "rewrite_1", "indexes" => [], "timed_out" => false,
          "measurements" => { "slow" => m(300, 30, stable: false), "typical" => m(100, 100) },
          "verdicts" => { "slow" => "better", "typical" => "better" } },
        { "label" => "rewrite_1:top:1", "search" => "rewrite_1", "indexes" => ["quaack_b"], "timed_out" => false,
          "measurements" => { "slow" => m(7777, 1), "typical" => m(100, 100) },
          "verdicts" => { "slow" => "worse", "typical" => "no_worse" } }
      ],
      "rewrites" => [
        { "rewrite" => "rewrite_1", "sql" => "SELECT id FROM t WHERE a < $1", "source" => "rule",
          "rules" => ["key_in_self_join"], "fate" => "ranked", "scenario" => nil, "rule" => nil, "round" => nil,
          "after" => nil,
          "plan" => [{ "node" => "Index Scan", "relation" => "public.t", "index" => "t_a_idx", "est_rows" => 5,
                       "actual_rows" => 5, "selectivity" => 0.005 }],
          "untested_atoms" => [{ "shape" => "a < $n" }], "evidence" => false }
      ],
      "indexes" => { "quaack_a" => { "ddl" => "CREATE INDEX ON public.t USING btree (created_at)", "size" => 8192,
                                     "covered_by" => { "name" => "t_created_at_id_idx", "size_bytes" => 40_960 },
                                     "makes_redundant" => [] },
                     "quaack_b" => { "ddl" => "CREATE INDEX ON public.t USING btree (a, b)", "size" => 16_384,
                                     "covered_by" => nil,
                                     "makes_redundant" => [{ "name" => "t_a_idx", "size_bytes" => 8192 },
                                                           { "name" => "t_a_b_idx", "size_bytes" => nil }] } },
      "original_plan" => [{ "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 50,
                            "actual_rows" => 50, "selectivity" => 0.05 }],
      "timed_out_count" => 2 }
  end

  let(:html) { described_class.render(payload, run_id: "RUN-1") }

  it "ranks the candidates overall, winner first" do
    expect(html.scan(%r{<tr class="rank"><td>(\d)</td><td>([^<]+)<})).to eq([%w[1 rewrite_1:none],
                                                                             %w[2 original:top:1]])
  end

  it "shows per-literal blocks with hit/read, verdicts, and unstable flags" do
    expect(html).to include("<td>slow</td><td>300</td><td>30</td><td>270</td><td>better</td><td>unstable</td>")
    expect(html).to include("<td>typical</td><td>190</td><td>190</td><td>0</td><td>no_worse</td><td></td>")
  end

  it "gives a section to each ranked candidate, in rank order, and to no other measured label" do
    expect(html.scan(%r{<section class="candidate"><h2>([^<]+)</h2>})).to eq([["rewrite_1:none"],
                                                                              ["original:top:1"]])
    expect(html).not_to include("7777")
  end

  it "lists the indexes each ranked candidate ran with" do
    expect(html[%r{<section class="candidate"><h2>original:top:1</h2>.*?</section>}m])
      .to include("<p>Indexes: quaack_a</p>")
    expect(html[%r{<section class="candidate"><h2>rewrite_1:none</h2>.*?</section>}m]).not_to include("Indexes:")
  end

  it "explains the winner from blocks, plan nodes, and selectivities" do
    expect(html).to include("rewrite_1:none reads 300 blocks on the slow literal set, against 1000 for the " \
                            "original (70% fewer)")
    expect(html).to include("Index Scan on public.t using t_a_idx (5 rows, selectivity 0.5%)")
    expect(html).to include("Seq Scan on public.t (50 rows, selectivity 5.0%)")
  end

  it "shows each query escaped, with the clock functions as the application wrote them" do
    expect(html).to include("SELECT id FROM t WHERE a &lt; $1")
    expect(html).to include("created_at &gt; now() - $1")
  end

  it "lists untested atoms and whether step 10 covered them" do
    expect(html).to include("a &lt; $n")
    expect(html).to include("no counterexample round loaded its inserts")
  end

  it "gives each index its size, prefix coverage, and redundancy" do
    expect(html).to include("<td>CREATE INDEX ON public.t USING btree (created_at)</td><td>8 kB</td>" \
                            "<td>t_created_at_id_idx</td><td></td>")
    expect(html).to include("<td>16 kB</td><td></td><td>t_a_idx, t_a_b_idx</td>")
  end

  it "says so when the enclave couldn't parse a built index's DDL" do
    payload["indexes"]["quaack_b"]["ddl"] = nil
    expect(html).to include("<td>quaack_b</td><td>(the enclave could not parse this DDL)</td><td>16 kB</td>")
  end

  describe "where a rewrite came from (6c)" do
    def candidate(**fields)
      payload["rewrites"].first.merge!(fields.transform_keys(&:to_s))
      rendered = described_class.render(payload, run_id: "RUN-1")
      rendered[%r{<section class="candidate"><h2>rewrite_1:none</h2>.*?</section>}m]
    end

    it "says which of QUAACK's rules made a rule-made rewrite" do
      expect(candidate).to include(%(<p class="source">Source: made by QUAACK's rule key_in_self_join.</p>)
        .gsub("'", "&#39;"))
    end

    it "names every rule of a chained rewrite, in order" do
      expect(candidate(rules: %w[or_to_union key_in_self_join]))
        .to include("Source: made by QUAACK&#39;s rules or_to_union, then key_in_self_join.")
    end

    it "says when the LLM proposed it, or it's the operator's own" do
      expect(candidate(source: "llm", rules: nil)).to include(%(<p class="source">Source: proposed by the LLM.</p>))
      expect(candidate(source: "operator", rules: nil)).to include(%(<p class="source">Source: your own rewrite.</p>))
    end

    it "says nothing for a rewrite with no source, or for the original query" do
      expect(candidate(source: nil, rules: nil)).not_to include("Source:")
      expect(html[%r{<section class="candidate"><h2>original:top:1</h2>.*?</section>}m]).not_to include("Source:")
    end

    it "escapes a rule name" do
      expect(candidate(rules: ["<b>"])).to include("rule &lt;b&gt;.").and(satisfy { !it.include?("<b>") })
    end
  end

  describe "a rule-made rewrite that a test disproved (6c)" do
    let(:bugs) do
      [{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"], "step" => "step9" },
       { "rewrite" => "rewrite_3", "rules" => %w[or_to_union key_in_self_join], "step" => "step10" },
       { "rewrite" => "rewrite_4", "rules" => ["<b>"], "step" => "14c" }]
    end
    let(:bug_html) { described_class.render(payload.merge("rule_bugs" => bugs), run_id: "RUN-1") }
    let(:section) { bug_html[%r{<section id="quaack-bugs">.*?</section>}m] }

    it "says so first, above the ranking, as a bug in QUAACK" do
      expect(bug_html.index(%(<section id="quaack-bugs">))).to be < bug_html.index(%(<section id="ranking">))
      expect(section).to include("<h2>QUAACK bug: a rule made a wrong rewrite</h2>")
      expect(section).to include("a rule has a bug")
    end

    it "names each rewrite, the rules that made it, and the step that disproved it" do
      expect(section).to include("<li>rewrite_2, made by QUAACK&#39;s rule key_in_self_join, " \
                                 "was disproved in step 9</li>")
      expect(section).to include("<li>rewrite_3, made by QUAACK&#39;s rules or_to_union, then key_in_self_join, " \
                                 "was disproved in step 10</li>")
      expect(section).to include("<li>rewrite_4, made by QUAACK&#39;s rule &lt;b&gt;, was disproved in step 14c, " \
                                 "on production data</li>")
      expect(section).not_to include("<b>")
    end

    it "is left out when no rule-made rewrite was disproved, or the enclave sent no list" do
      expect(described_class.render(payload.merge("rule_bugs" => []), run_id: "RUN-1")).not_to include("quaack-bugs")
      expect(html).not_to include("quaack-bugs")
    end
  end

  it "leaves the negative result empty when a candidate beat the original" do
    expect(html).to include(%(<section id="negative-result"></section>))
  end

  describe "the burndown (15b)" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    let(:burndown) do
      { "stages" => {
          "5a-1" => { "original" => rec(0, 3, added: { "generator_one" => 3 }) },
          "5a-3" => { "original" => rec(4, 3, dropped: { "duplicate" => 1 }),
                      "rewrite_1" => rec(2, 1, dropped: { "covered_by_existing" => 1 }),
                      "rewrite_2" => rec(3, 1, dropped: { "covered_by_existing" => 1 }, set_aside: 1) },
          "step9" => { "rewrites" => rec(2, 1, dropped: { "s3" => 1 }, extra: { "untested_atoms" => 2 }) },
          "6c" => { "rewrites" => rec(0, 1, added: { "key_in_self_join" => 2 },
                                            dropped: { "duplicate" => 1, "over_cap" => 0, "failed_checks" => 0 }) }
        },
        "totals" => { "hypothetical_explains" => 12, "fixture_loads" => 3 } }
    end

    let(:section) do
      described_class.render(payload.merge("burndown" => burndown), run_id: "RUN-1",
                                                                    llm_calls: { "5a-5" => 2, "6a" => 1 })[
        %r{<section id="burndown">.*?</section>}m
      ]
    end

    it "shows the original's index candidates stage by stage, drops by reason" do
      index = section[%r{<table id="burndown-index">.*?</table>}m]
      expect(index).to include("<tr><td>5a-1</td><td>0</td><td>generator_one: 3</td><td></td><td>0</td><td>3</td>" \
                               "<td></td></tr>")
      expect(index).to include("<tr><td>5a-3</td><td>4</td><td></td><td>duplicate: 1</td><td>0</td><td>3</td>" \
                               "<td></td></tr>")
    end

    it "shows the rewrites, with the rewrites' own index searches totaled" do
      rewrites = section[%r{<table id="burndown-rewrite">.*?</table>}m]
      expect(rewrites).to include("<tr><td>step9</td><td>2</td><td></td><td>s3: 1</td><td>0</td><td>1</td>" \
                                  "<td>untested_atoms: 2</td></tr>")
      expect(rewrites).to include("<tr><td>Steps 8 and 11: 5a-3</td><td>5</td><td></td>" \
                                  "<td>covered_by_existing: 2</td><td>1</td><td>2</td><td></td></tr>")
    end

    it "shows the 6c row first among the rewrites: what each rule made, and what was dropped" do
      rewrites = section[%r{<table id="burndown-rewrite">.*?</table>}m]
      row = "<tr><td>6c</td><td>0</td><td>key_in_self_join: 2</td>" \
            "<td>duplicate: 1, over_cap: 0, failed_checks: 0</td><td>0</td><td>1</td><td></td></tr>"
      expect(rewrites).to include(row)
      expect(rewrites.index(row)).to be < rewrites.index("<tr><td>step9</td>")
    end

    it "shows the work totals, with LLM calls by step" do
      totals = section[%r{<ul id="burndown-totals">.*?</ul>}m]
      expect(totals).to include("<li>LLM calls, 5a-5: 2</li>").and include("<li>LLM calls, 6a: 1</li>")
      expect(totals).to include("<li>hypothetical_explains: 12</li>").and include("<li>fixture_loads: 3</li>")
    end

    it "escapes the names it shows" do
      burndown["stages"]["5a-3"]["original"]["dropped"] = { "<b>" => 1 }
      expect(section).to include("&lt;b&gt;: 1")
      expect(section).not_to include("<b>")
    end
  end

  describe "when nothing beat the original (15a)" do
    def fated(number, fate, **details)
      { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => nil, "rules" => nil,
        "fate" => fate, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
        "untested_atoms" => nil, "evidence" => nil }.merge(details.transform_keys(&:to_s))
    end

    let(:rewrites) do
      [fated(2, "step9_disproved", scenario: "s3", rule: "<multiset>"),
       fated(3, "step10_disproved", round: 2, rule: "row_count", source: "llm"),
       fated(4, "step10_disproved"),
       fated(5, "not_better", source: "rule", rules: ["key_in_self_join"]),
       fated(6, "production_mismatch", rule: "multiset"),
       fated(7, "same_plans"),
       fated(8, "step9_failed", scenario: "s0", rule: "unsupported_order"),
       fated(9, "step10_failed", round: 1, rule: "statement_timeout"),
       fated(10, "footprint_tie"),
       fated(11, "production_timed_out"),
       fated(12, "production_not_compared", rule: "unsupported_order"),
       fated(13, "measurement_timed_out"),
       fated(14, "unfinished", after: "step9")]
    end

    let(:negative_html) do
      by = { "name" => "t_c_d_idx", "size_bytes" => 8192 }
      described_class.render(
        payload.merge(
          "top" => [], "rewrites" => rewrites,
          "negative" => {
            "declined" => [{ "ddl" => "CREATE INDEX ON public.t USING btree (a) WHERE a < ?", "reason" => "unused",
                             "sqlstate" => nil, "searches" => %w[original rewrite_1] },
                           { "ddl" => "CREATE INDEX ON public.t USING gin (b)", "reason" => "hypopg_refused",
                             "sqlstate" => "0A000", "searches" => ["rewrite_1"] }],
            "existing" => [{ "ddl" => "CREATE INDEX ON public.t USING btree (c)", "covered_by" => by,
                             "searches" => %w[original rewrite_2] }]
          }
        ), run_id: "RUN-1"
      )
    end

    let(:section) { negative_html[%r{<section id="negative-result">.*?</section>}m] }
    let(:disproved) { section[%r{<p>Rewrites disproved:</p><ul>.*?</ul>}m] }
    let(:knocked_out) { section[%r{<p>Rewrites that passed steps 9 and 10 but were knocked out:</p><ul>.*?</ul>}m] }

    it "says which rewrites were disproved, and by which scenario or round" do
      expect(disproved).to include("<li>rewrite_2: disproved in step 9 by scenario s3 (rule &lt;multiset&gt;)</li>")
      expect(disproved).to include("<li>rewrite_3 (proposed by the LLM): disproved in step 10, " \
                                   "counterexample round 2</li>")
      expect(disproved).to include("<li>rewrite_4: disproved in step 10</li>")
    end

    it "never calls a rewrite that step 8 pruned disproved" do
      expect(disproved.scan(/<li>(rewrite_\d+)/).flatten).to eq(%w[rewrite_2 rewrite_3 rewrite_4 rewrite_8
                                                                   rewrite_9])
      expect(section).not_to include("rewrite_7")
      expect(section).not_to include("discarded")
    end

    it "says a step 9 or step 10 failure compared nothing, and doesn't call it a disproof" do
      expect(disproved).to include("<li>rewrite_8: dropped, not disproved: step 9 failed in scenario s0 without " \
                                   "comparing results (rule unsupported_order)</li>")
      expect(disproved).to include("<li>rewrite_9: dropped, not disproved: step 10 failed in counterexample round 1 " \
                                   "without comparing results (rule statement_timeout)</li>")
    end

    it "says which rewrites passed steps 9 and 10 but minimax or 14c knocked out" do
      expect(knocked_out).to include("<li>rewrite_5 (made by QUAACK&#39;s rule key_in_self_join): passed steps 9 " \
                                     "and 10, but minimax found it not better than the original</li>")
      expect(knocked_out).to include("<li>rewrite_6: passed steps 9 and 10, but its results didn't match " \
                                     "the original's in 14c</li>".gsub("'", "&#39;"))
      expect(knocked_out).to include("<li>rewrite_10: passed steps 9 and 10, but minimax dropped it for tying a " \
                                     "candidate with a smaller index footprint</li>")
    end

    it "says when 14c or the measurement dropped a rewrite without comparing it, not that its results differed" do
      expect(knocked_out).to include("<li>rewrite_11: passed steps 9 and 10, but 14c timed out before comparing " \
                                     "its results</li>")
      expect(knocked_out).to include("<li>rewrite_12: passed steps 9 and 10, but 14c couldn&#39;t compare its " \
                                     "results</li>")
      expect(knocked_out).to include("<li>rewrite_13: passed steps 9 and 10, but every measurement run of it " \
                                     "timed out</li>")
      expect(knocked_out.scan(/<li>(rewrite_\d+)/).flatten).to eq(%w[rewrite_5 rewrite_6 rewrite_10 rewrite_11
                                                                     rewrite_12 rewrite_13])
    end

    it "says which indexes the planner declined, and why, once each, with the searches" do
      expect(section).to include("<li>original, rewrite_1: CREATE INDEX ON public.t USING btree (a) WHERE a &lt; ?: " \
                                 "the planner never used it</li>")
      expect(section).to include("<li>rewrite_1: CREATE INDEX ON public.t USING gin (b): HypoPG refused it " \
                                 "(SQLSTATE 0A000)</li>")
    end

    it "says which proposed indexes already existed" do
      expect(section).to include("<li>original, rewrite_2: CREATE INDEX ON public.t USING btree (c): already " \
                                 "covered by t_c_d_idx</li>")
    end
  end
end
