# frozen_string_literal: true

require "tmpdir"
require "quaack/driver/report"

RSpec.describe Quaack::Driver::Report do
  def m(blocks, hit, stable: true)
    { "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "stable" => stable, "timed_out" => false }
  end

  # What ERB's escaping makes of text with an apostrophe in it.
  def esc(text) = text.gsub("'", "&#39;")

  def render(payload, **) = described_class.render(payload, run_id: "RUN-1", **)

  def section(html, id) = html[%r{<section id="#{id}">.*?</section>}m]

  # SQL as the report sets it apart from the words around it.
  def sq(text) = %(<code class="sql">#{text}</code>)

  def fated(number, fate, **details)
    { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => nil, "rules" => nil,
      "fate" => fate, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
      "untested_atoms" => nil, "covered" => nil, "evidence" => nil }.merge(details.transform_keys(&:to_s))
  end

  let(:payload) do
    { "type" => "report",
      "top" => [{ "label" => "rewrite_1:none", "slow_blocks" => 300, "total_blocks_sum" => 400, "footprint" => 0 },
                { "label" => "original:top:1", "slow_blocks" => 400, "total_blocks_sum" => 590,
                  "footprint" => 8192 }],
      "excluded" => { "rewrite_1:top:1" => "not_better" }, "infinite_sets" => [],
      "original_sql" => "SELECT id FROM t WHERE created_at > now() - $1 AND b IN (SELECT b FROM u WHERE c = $2)",
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
        { "rewrite" => "rewrite_1", "sql" => "SELECT id FROM t WHERE a < $1 ORDER BY id", "source" => "rule",
          "rules" => ["key_in_self_join"], "fate" => "ranked", "scenario" => nil, "rule" => nil, "round" => nil,
          "after" => nil,
          "plan" => [{ "node" => "Index Scan", "relation" => "public.t", "index" => "t_a_idx", "est_rows" => 5,
                       "actual_rows" => 5, "selectivity" => 0.005, "depth" => 0 }],
          "untested_atoms" => ["a < $1"], "covered" => nil, "evidence" => nil }
      ],
      "indexes" => { "quaack_a" => { "ddl" => "CREATE INDEX ON public.t USING btree (created_at)", "size" => 8192,
                                     "covered_by" => { "name" => "t_created_at_id_idx", "size_bytes" => 40_960 },
                                     "makes_redundant" => [] },
                     "quaack_b" => { "ddl" => "CREATE INDEX ON public.t USING btree (a, b)", "size" => 16_384,
                                     "covered_by" => nil,
                                     "makes_redundant" => [{ "name" => "t_a_idx", "size_bytes" => 8192 },
                                                           { "name" => "t_a_b_idx", "size_bytes" => nil }] } },
      "original_plan" => [{ "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 50,
                            "actual_rows" => 50, "selectivity" => 0.05, "depth" => 0 }],
      "timed_out_count" => 2 }
  end

  let(:html) { render(payload) }

  let(:negative) do
    by = { "name" => "t_c_d_idx", "size_bytes" => 3 * 1024 * 1024 }
    { "declined" => [{ "ddl" => "CREATE INDEX ON public.t USING btree (a) WHERE a < ?", "reason" => "unused",
                       "sqlstate" => nil, "searches" => %w[original rewrite_1] },
                     { "ddl" => "CREATE INDEX ON public.t USING gin (b)", "reason" => "hypopg_refused",
                       "sqlstate" => "0A000", "searches" => ["rewrite_1"] },
                     { "ddl" => nil, "reason" => "unrenderable", "sqlstate" => nil, "searches" => ["original"] }],
      "existing" => [{ "ddl" => "CREATE INDEX ON public.t USING btree (c)", "covered_by" => by,
                       "searches" => %w[original rewrite_2] }] }
  end

  # Nothing ranked: each label read about what the original did.
  let(:negative_payload) do
    payload["labels"][0].merge!("measurements" => { "slow" => m(990, 300), "typical" => m(190, 190) },
                                "verdicts" => { "slow" => "no_worse", "typical" => "no_worse" })
    payload["labels"][1].merge!("measurements" => { "slow" => m(980, 30), "typical" => m(200, 100) },
                                "verdicts" => { "slow" => "no_worse", "typical" => "no_worse" })
    payload.merge("top" => [], "negative" => negative,
                  "excluded" => { "original:top:1" => "not_better", "rewrite_1:none" => "not_better",
                                  "rewrite_1:top:1" => "not_better" })
  end

  describe "the layout" do
    it "is one file of plain HTML and CSS: no scripts, no animation, nothing from the network" do
      expect(html).to start_with("<!DOCTYPE html>").and include("<style>")
      expect(html).not_to match(/<script|<link|<img|<iframe|https?:|url\(|@import|animation|transition|src=/i)
    end

    it "loads nothing from the network in a negative report either" do
      expect(render(negative_payload)).not_to match(/<script|<link|<img|https?:|url\(|@import|animation|src=/i)
    end

    it "sets inline SQL apart in monospace on a subtle background, wrapping long DDL inside the page" do
      rule = html[/^\s*code\.sql\s*\{[^}]*\}/]
      expect(rule).to match(/background:\s*#f3f5f8/).and match(/overflow-wrap:\s*break-word/)
        .and match(/white-space:\s*pre-wrap/)
      expect(html).to match(/^\s*code, pre \{ font-family: ui-monospace, Menlo, Consolas, monospace;/)
    end

    it "marks the placeholders in the queries' note as SQL" do
      expect(section(html, "queries")).to include("Each #{sq("$1")}, #{sq("$2")}, and so on stands for")
    end

    it "right-aligns numbers, and puts SQL in code blocks" do
      expect(html).to match(/td\.num,\s*th\.num\s*\{[^}]*text-align:\s*right/)
      expect(html).to include(%(<pre class="sql"><code>SELECT id))
    end

    it "puts the verdict first, then the queries, the ranking, the indexes, who proposed what, and the burndown" do
      ids = html.scan(/<section id="([a-z-]+)">/).flatten
      expect(ids).to eq(%w[summary queries ranking explanation indexes accountability burndown])
    end

    it "calls each rewrite by its name, never its number, in a winning report and a negative one" do
      bugs = { "rule_bugs" => [{ "rewrite" => "rewrite_1", "rules" => ["key_in_self_join"],
                                 "step" => "rewrite-test" }] }
      [render(payload.merge(bugs)), render(negative_payload.merge("negative" => negative).merge(bugs))].each do |html|
        expect(html).not_to match(/rewrite \d/i)
        expect(html.scan(/rewrite Vivid Cove/i).size).to be >= 3
      end
    end

    it "shows no internal label, verdict name, or built index name" do
      expect(html).not_to match(/rewrite_1|original:top|not_better|no_worse|quaack_[ab]|step ?\d|5a-|6[abc]\b/)
      expect(html).not_to match(/llm-index|llm-rewrites|rewrite-rules|plan-pruning/)
    end
  end

  describe "the summary" do
    it "says what won, and by how much, in words" do
      expect(section(html, "summary")).to include(
        "QUAACK found something better than your query as it is: rewrite Vivid Cove with no new indexes. It read 300 " \
        "blocks on the slow values, against 1,000 for your query as it is (70% fewer)."
      )
    end

    it "says over 99% fewer, as the winner's table does, when rounding would say all of them" do
      payload["top"][0]["slow_blocks"] = 12
      payload["original_measurements"]["slow"] = m(5120, 0)
      expect(section(html, "summary")).to include("It read 12 blocks on the slow values, against 5,120 for your " \
                                                  "query as it is (over 99% fewer).")
    end

    it "says a candidate won where the original timed out" do
      payload["original_measurements"]["slow"] = { "timed_out" => true }
      payload["infinite_sets"] = ["slow"]
      expect(section(html, "summary")).to include("It read 300 blocks on the slow values, where your query as it " \
                                                  "is timed out.")
      expect(section(html, "summary")).to include("Your query as it is timed out on the slow values")
    end

    it "says how many measurement runs timed out, and nothing when none did" do
      expect(section(html, "summary")).to include("2 measurement runs of candidates timed out")
      payload["timed_out_count"] = 0
      expect(section(render(payload), "summary")).not_to include("timed out")
    end

    it "says nothing beat the query, and how much was tried" do
      summary = section(render(negative_payload), "summary")
      expect(summary).to include("Nothing QUAACK tried beat your query as it is.")
      expect(summary).to include("It built and measured 2 indexes and kept 1 rewrite.")
      expect(summary).not_to include("found something better")
    end
  end

  describe "the queries" do
    let(:queries) { section(html, "queries") }

    it "gives each rewrite in the payload its name, next to its number" do
      named = described_class.named(payload.merge("rule_bugs" => [{ "rewrite" => "rewrite_2", "rules" => [] }]),
                                    "RUN-1")
      expect(named["rewrites"].map { it.slice("rewrite", "name") })
        .to eq([{ "rewrite" => "rewrite_1", "name" => "Vivid Cove" }])
      expect(named["rule_bugs"]).to eq([{ "rewrite" => "rewrite_2", "rules" => [], "name" => "Smooth Kayak" }])
      expect(payload["rewrites"].first).not_to have_key("name")
    end

    it "gives a rewrite with no number, or none past the last name, no name" do
      past_last = "rewrite_#{Quaack::Driver::RewriteNames.size + 1}"
      odd = payload.merge("rewrites" => [fated(1, "ranked", rewrite: "<b>"), fated(1, "ranked", rewrite: past_last)])
      expect(described_class.named(odd, "RUN-1")["rewrites"].map { it["name"] }).to eq([nil, nil])
      expect(described_class.named(payload.merge("rewrites" => []), "RUN-1")).not_to have_key("rule_bugs")
    end

    it "shows the original query first, pretty-printed, with its placeholders and clock functions" do
      expect(queries).to include(
        "<h3>Your query</h3></summary>\n<pre class=\"sql\"><code>SELECT id\nFROM t\nWHERE\n  " \
        "created_at &gt; (now() - $1)\n  " \
        "AND b IN (\n    SELECT b\n    FROM u\n    WHERE c = $2\n  )</code></pre>"
      )
      expect(queries.index("<h3>Your query</h3>")).to be < queries.index("<h3>Rewrite Vivid Cove</h3>")
    end

    it "shows every rewrite, ranked or not, pretty-printed, in order" do
      payload["rewrites"] << fated(2, "same_plans", sql: "SELECT id FROM t WHERE b = $1 LIMIT 5")
      opening = %(<details class="query">\n<summary>)
      expect(queries.scan(%r{<article class="rewrite" id="rewrite-(\d+)">#{opening}<h3>([^<]+)</h3>}))
        .to eq([["1", "Rewrite Vivid Cove"], ["2", "Rewrite Smooth Kayak"]])
      expect(queries).to include("<code>SELECT id\nFROM t\nWHERE a &lt; $1\nORDER BY id</code>")
      expect(queries).to include("<code>SELECT id\nFROM t\nWHERE b = $1\nLIMIT 5</code>")
    end

    it "keeps each query's SQL behind its own collapsed section, with the rewrite's name, source, and fate on top" do
      payload["rewrites"] << fated(2, "same_plans", sql: "SELECT id FROM t WHERE b = $1 LIMIT 5", source: "llm")
      same_plans = esc("Postgres plans it exactly as it plans your query, so it can't run any differently. " \
                       "QUAACK didn't test it further.")
      blocks = queries.scan(%r{<details class="query">\s*<summary>(.*?)</summary>(.*?)</details>}m)
      expect(blocks.map(&:first)).to eq(
        ["<h3>Your query</h3>",
         "<h3>Rewrite Vivid Cove</h3> <span class=\"source\">Where it came from: made by QUAACK&#39;s own rewrite " \
         "rule key_in_self_join.</span> <span class=\"fate\">What became of it: It beat your query and is ranked " \
         "below.</span>",
         "<h3>Rewrite Smooth Kayak</h3> <span class=\"source\">Where it came from: suggested by the LLM.</span> " \
         "<span class=\"fate\">What became of it: #{same_plans}</span>"]
      )
      expect(blocks.map { it.last.scan('<pre class="sql">').size }).to eq([1, 1, 1])
      expect(blocks[1].last).to include(%(<li><code class="sql">a &lt; $1</code></li>))
      expect(queries.scan('<pre class="sql">').size).to eq(3)
      expect(queries).not_to match(/<details[^>]*\bopen\b/)
    end

    it "shows SQL that pg_query can't parse as it was sent, escaped" do
      payload["rewrites"].first["sql"] = "SELECT FROM WHERE <b> $1"
      expect(queries).to include("<code>SELECT FROM WHERE &lt;b&gt; $1</code>")
    end

    describe "the conditions QUAACK's made-up rows never checked (vacuity-guard)" do
      let(:explained) do
        esc("QUAACK tests a rewrite on rows it makes up, to check that it returns what your query returns. " \
            "Those rows never made the conditions below, from your query&#39;s WHERE and JOIN clauses, both true " \
            "and false, so a rewrite that changed one of them could still have passed.")
      end

      def conditions(atoms, covered)
        payload["rewrites"].first.merge!("untested_atoms" => atoms, "covered" => covered)
        section(render(payload), "queries")[%r{<div class="untested">.*?</div>}m]
      end

      it "says what they are and why they matter, and lists each as SQL" do
        out = conditions(["a < $1", "t.b IS NULL"], nil)
        expect(out).to start_with(%(<div class="untested"><p>#{explained} No later test checked them.</p>))
        expect(out).to include(%(<ul><li><code class="sql">a &lt; $1</code></li>) +
                               %(<li><code class="sql">t.b IS NULL</code></li></ul>))
      end

      it "says the LLM's test data didn't check them either, when counterexamples ran and covered none" do
        expect(conditions(["a < $1"], [])).to include(
          esc("The test data the LLM wrote afterwards to break the rewrite didn't check them either.</p>")
        )
      end

      it "marks those the LLM's test data checked afterwards, when it checked some" do
        out = conditions(["a < $1", "t.b IS NULL"], ["t.b IS NULL"])
        expect(out).to include(esc("The test data the LLM wrote afterwards to break the rewrite checked the ones " \
                                   "marked “checked later”, but not the others.</p>"))
        expect(out).to include(%(<li><code class="sql">a &lt; $1</code></li>) +
                               %(<li><code class="sql">t.b IS NULL</code> (checked later)</li>))
        expect(out).not_to include("<details")
      end

      it "collapses the list when the LLM's test data checked them all afterwards" do
        out = conditions(["a < $1", "t.b IS NULL"], ["t.b IS NULL", "a < $1"])
        expect(out).to include(esc("The test data the LLM wrote afterwards to break the rewrite checked all of " \
                                   "them, so none is left unchecked.</p>"))
        expect(out).to include(%(<details class="untested"><summary>The 2 conditions</summary><ul>) +
                               %(<li><code class="sql">a &lt; $1</code> (checked later)</li>))
      end

      it "never lists a value that isn't a condition's SQL, such as an atom's index" do
        out = conditions([0, "a < $1", { "shape" => "b = $2" }, 13], nil)
        expect(out.scan(%r{<li>.*?</li>})).to eq([%(<li><code class="sql">a &lt; $1</code></li>)])
      end
    end

    it "lists no untested conditions for a rewrite that has none, or wasn't tested" do
      payload["rewrites"].first["untested_atoms"] = []
      payload["rewrites"] << fated(2, "same_plans")
      expect(queries).not_to include("never exercised")
    end

    describe "where a rewrite came from (rewrite-rules)" do
      def source(**fields)
        payload["rewrites"].first.merge!(fields.transform_keys(&:to_s))
        section(render(payload), "queries")[%r{<span class="source">.*?</span>}m]
      end

      it "says which of QUAACK's rules made a rule-made rewrite" do
        expect(source).to eq(esc(%(<span class="source">Where it came from: made by QUAACK's own rewrite rule ) +
                                 %(key_in_self_join.</span>)))
      end

      it "names every rule of a chained rewrite, in order" do
        expect(source(rules: %w[or_to_union key_in_self_join]))
          .to include(esc("made by QUAACK's own rewrite rules or_to_union, then key_in_self_join."))
      end

      it "names no rule, and leaves no dangling words, when the payload has none" do
        expect(source(rules: [])).to include(esc("Where it came from: made by QUAACK's own rewrite rules.</span>"))
        expect(source(rules: nil)).to include(esc("Where it came from: made by QUAACK's own rewrite rules.</span>"))
      end

      it "says when the LLM suggested it, or it's the operator's own" do
        expect(source(source: "llm", rules: nil)).to include("Where it came from: suggested by the LLM.")
        expect(source(source: "operator", rules: nil)).to include("Where it came from: your own rewrite.")
      end

      it "says the source wasn't recorded when the payload has none" do
        expect(source(source: nil, rules: nil)).to include("Where it came from: not recorded.")
      end

      it "escapes a rule name" do
        expect(source(rules: ["<b>"])).to include("rule &lt;b&gt;.").and(satisfy { !it.include?("<b>") })
      end
    end

    describe "what a rule-made rewrite assumes of the data (assumption-check)" do
      def empirical(*assumptions)
        payload["rewrites"].first.merge!("rules" => ["polymorphic_key_copy"], "empirical" => assumptions)
        section(render(payload), "queries")[%r{<p class="empirical">.*?</p>}m]
      end

      def copy(**fields)
        { "table" => "public.submissions", "column" => "course_id", "references_table" => "public.assignments",
          "type_column" => "context_type", "id_column" => "context_id" }.merge(fields.transform_keys(&:to_s))
      end

      it "says the rewrite rests on what the data holds today, not on the schema, naming the columns" do
        expect(empirical(copy)).to eq(esc(
                                        '<p class="empirical">It rests on something your data holds today but ' \
                                        "your schema doesn't enforce: #{sq("public.submissions.course_id")} equals " \
                                        "#{sq("public.assignments.context_id")} wherever " \
                                        "#{sq("public.assignments.context_type")} " \
                                        "names the type in your query. QUAACK checked it on the real data.</p>"
                                      ))
      end

      it "names each assumption when there are several" do
        expect(empirical(copy, copy(column: "account_id"))).to include("#{sq("public.submissions.course_id")} equals")
          .and include("; #{sq("public.submissions.account_id")} equals")
      end

      it "says nothing when the rewrite rests on none" do
        expect(empirical).to be_nil
        payload["rewrites"].first.delete("empirical")
        expect(section(render(payload), "queries")).not_to include("empirical")
      end

      it "escapes a name" do
        expect(empirical(copy(column: "<b>"))).to include("#{sq("public.submissions.&lt;b&gt;")} equals")
          .and(satisfy { !it.include?("<b>") })
      end
    end

    describe "what became of a rewrite" do
      def fate(name, **details)
        payload["rewrites"] = [fated(2, name, **details)]
        section(render(payload), "queries")[%r{<span class="fate">What became of it: (.*?)</span>}m, 1]
      end

      it "says a ranked rewrite is ranked" do
        expect(fate("ranked")).to eq("It beat your query and is ranked below.")
      end

      it "says a rewrite that plans as the original does was never tested" do
        expect(fate("same_plans")).to eq(esc("Postgres plans it exactly as it plans your query, so it can't run " \
                                             "any differently. QUAACK didn't test it further."))
      end

      it "says which made-up data proved a rewrite wrong" do
        expect(fate("rewrite_test_disproved", scenario: "s2", rule: "multiset"))
          .to eq(esc("It returned different results from your query on made-up test data (NULLs), so it's wrong."))
        expect(fate("rewrite_test_disproved", scenario: "s3", rule: "row_count")).to include("(duplicate join keys)")
      end

      it "says which round of LLM-written data proved a rewrite wrong" do
        expect(fate("counterexamples_disproved", round: 2, rule: "row_count"))
          .to eq(esc("It returned different results from your query on test data the LLM wrote to break it " \
                     "(round 2), so it's wrong."))
      end

      it "leaves out a scenario or round the payload doesn't have, with no stray brackets" do
        expect(fate("rewrite_test_disproved"))
          .to eq(esc("It returned different results from your query on made-up test data, so it's wrong."))
        expect(fate("counterexamples_disproved"))
          .to eq(esc("It returned different results from your query on test data the LLM wrote to break it, so " \
                     "it's wrong."))
        expect(fate("rewrite_test_failed"))
          .to eq(esc("A test on made-up data ended without comparing results, so QUAACK dropped it. That says " \
                     "nothing about whether it's right."))
        expect(fate("counterexamples_failed"))
          .to eq(esc("A test on data the LLM wrote to break it ended without comparing results, so QUAACK dropped " \
                     "it. That says nothing about whether it's right."))
      end

      it "says why a test compared nothing" do
        expect(fate("rewrite_test_failed", scenario: "s0", rule: "unsupported_order"))
          .to eq(esc("A test on made-up data (empty tables) ended without comparing results, because the order " \
                     "of your query's rows can't be checked, so QUAACK dropped it. That says nothing about " \
                     "whether it's right."))
        expect(fate("counterexamples_failed", round: 1, rule: "statement_timeout"))
          .to include("(round 1) ended without comparing results, because a statement timed out, so")
        expect(fate("rewrite_test_failed", scenario: "s1", rule: "query_failed"))
          .to include("ended without comparing results, because a statement failed on the test database, so")
      end

      it "says a rewrite was never tested when rewrite-test couldn't build test data, and why, by rule" do
        expect(fate("rewrite_test_untested", rule: "complex_check"))
          .to eq(esc("QUAACK couldn't make up test data for your query, because a CHECK constraint on its tables " \
                     "is too complex for QUAACK to satisfy, so it never tested this rewrite and won't recommend " \
                     "it. That says nothing about whether it's right."))
        {
          "fk_cycle" => "its tables' foreign keys form a cycle QUAACK can't load",
          "unsupported_type" => "a column has a type QUAACK can't fill",
          "expression_unique_index" => "a unique index on an expression calls a function QUAACK can't trust",
          "unsatisfiable_check" => "no value QUAACK tried passes a CHECK constraint on its tables",
          "domain_check" => "a column's domain rejects every value QUAACK tried"
        }.each do |rule, words|
          expect(fate("rewrite_test_untested", rule:)).to include(esc("for your query, because #{words}, so it never"))
        end
        expect(fate("rewrite_test_untested"))
          .to eq(esc("QUAACK couldn't make up test data for your query, so it never tested this rewrite and won't " \
                     "recommend it. That says nothing about whether it's right."))
      end

      it "names the tables of an fk_cycle refusal, in the order their foreign keys point" do
        expect(fate("rewrite_test_untested", rule: "fk_cycle",
                                             cycle: %w[public.accounts public.courses public.accounts]))
          .to eq(esc("QUAACK couldn't make up test data for your query, because its tables' foreign keys form a " \
                     "cycle QUAACK can't load (#{sq("public.accounts")} -&gt; #{sq("public.courses")} -&gt; " \
                     "#{sq("public.accounts")}), so it " \
                     "never tested this rewrite and won't recommend it. That says nothing about whether it's right."))
        expect(fate("rewrite_test_untested", rule: "fk_cycle", cycle: %w[public.<b> public.a public.<b>]))
          .to include("(#{sq("public.&lt;b&gt;")} -&gt; #{sq("public.a")} -&gt; #{sq("public.&lt;b&gt;")})")
      end

      it "names no tables for another rule, or a cycle that isn't a list of names" do
        expect(fate("rewrite_test_untested", rule: "complex_check", cycle: %w[public.a public.b public.a]))
          .not_to include("public.a")
        expect(fate("rewrite_test_untested", rule: "fk_cycle", cycle: "public.a"))
          .to include(esc("load, so it never")).and(satisfy { !it.include?("public.a") })
        expect(fate("rewrite_test_untested", rule: "fk_cycle", cycle: []))
          .to include(esc("QUAACK can't load, so it never"))
      end

      it "says what the real data showed" do
        expect(fate("production_mismatch", rule: "multiset"))
          .to eq(esc("It passed the tests on made-up data, but returned different results from your query on the " \
                     "real data, so it's wrong."))
        expect(fate("production_timed_out")).to include("but timed out when QUAACK compared its results with")
        expect(fate("production_not_compared", rule: "unsupported_order"))
          .to include(esc("but QUAACK couldn't compare its results with your query's on the real data, because " \
                          "the order of your query's rows can't be checked, so"))
        expect(fate("production_not_compared")).to include(esc("on the real data, so QUAACK dropped it."))
      end

      it "says how a rewrite that passed every test lost" do
        expect(fate("not_better")).to start_with(esc("It passed every test, but didn't read enough fewer blocks"))
        expect(fate("footprint_tie")).to include("tied with a candidate whose new indexes take less disk space")
        expect(fate("below_top_three")).to include("three other candidates did better")
        expect(fate("measurement_timed_out")).to include("every measurement run of it timed out")
      end

      it "says how far an unfinished rewrite got" do
        expect(fate("unfinished")).to eq("QUAACK kept it, but the run ended before testing it.")
        expect(fate("unfinished",
                    after: "rewrite-test")).to include("passed the tests on made-up data, and the run ended")
        expect(fate("unfinished", after: "counterexamples")).to include("passed every test, and the run ended before")
        expect(fate("unfinished", after: "measurement")).to include("was measured, and the run ended before")
      end

      it "never calls a failed, timed-out, or unfinished rewrite wrong" do
        [["rewrite_test_failed", { scenario: "s0", rule: "unsupported_order" }],
         ["counterexamples_failed", { round: 1 }],
         ["rewrite_test_untested", { rule: "complex_check" }],
         ["production_timed_out", {}], ["production_not_compared", {}], ["measurement_timed_out", {}],
         ["unfinished", {}], ["unfinished", { after: "rewrite-test" }], ["same_plans", {}], ["not_better", {}],
         ["footprint_tie", {}], ["below_top_three", {}]].each do |name, details|
          expect(fate(name, **details)).not_to match(/wrong|different results|disproved/)
        end
      end

      it "says so when the payload's fate is one it doesn't know" do
        expect(fate("mystery")).to eq("not recorded.")
        expect(fate(nil)).to eq("not recorded.")
      end
    end
  end

  describe "the ranking" do
    let(:ranking) { section(html, "ranking") }

    it "ranks the candidates overall, winner first, each described in words" do
      expect(ranking.scan(%r{<tr class="rank"><td class="num">(\d)</td><td>(.*?)</td>}))
        .to eq([["1", "Rewrite Vivid Cove with no new indexes"],
                ["2", "Your query with a new index on #{sq("public.t (created_at)")}"]])
    end

    it "shows each candidate's blocks and index footprint, right-aligned, with separators and a fitting unit" do
      payload["top"][1].merge!("slow_blocks" => 12_345, "total_blocks_sum" => 1_234_567, "footprint" => 5_000_000)
      expect(ranking).to include('<td class="num">12,345</td><td class="num">1,234,567</td>' \
                                 '<td class="num">4.8 MB</td></tr>')
      expect(ranking).to include('<td class="num">300</td><td class="num">400</td><td class="num">0 kB</td></tr>')
    end

    describe "your query as it is, for comparison" do
      def baseline(html = ranking) = html[%r{<tr class="baseline">.*?</tr>}m]

      it "is a row above the ranked ones, with no rank, marked as the baseline, with its own blocks" do
        expect(ranking.scan(/<tr class="(\w+)"/).flatten).to eq(%w[baseline rank rank])
        expect(baseline).to eq('<tr class="baseline"><td class="num"></td><td>Your query as it is (the baseline, ' \
                               'not ranked)</td><td class="num">1,000</td><td class="num">1,200</td>' \
                               '<td class="num">none</td></tr>')
      end

      it "sums its blocks over the same sets of values as the candidates, with separators" do
        payload["original_measurements"]["worst_case"] = m(1_234_000, 0)
        payload["labels"][0]["measurements"]["worst_case"] = m(5, 0)
        expect(baseline).to include('<td class="num">1,000</td><td class="num">1,235,200</td>')
      end

      it "says not recorded, never zero, for a number the payload doesn't carry" do
        payload["original_measurements"].delete("slow")
        payload["labels"][0]["measurements"]["worst_case"] = m(5, 0)
        expect(baseline).to include('<td class="num">not recorded</td><td class="num">not recorded</td>')
        payload["original_measurements"] = { "slow" => { "timed_out" => false }, "typical" => m(200, 150) }
        expect(baseline(section(render(payload), "ranking")))
          .to include('<td class="num">not recorded</td><td class="num">not recorded</td>')
      end

      it "says timed out where your query timed out" do
        payload["original_measurements"]["slow"] = { "timed_out" => true }
        payload["infinite_sets"] = ["slow"]
        expect(baseline).to include('<td class="num">timed out</td><td class="num">timed out</td>')
      end

      it "says timed out in the sum, but not for the slow values, where your query timed out on another set" do
        payload["original_measurements"]["worst_case"] = { "timed_out" => true }
        payload["infinite_sets"] = ["worst_case"]
        payload["labels"][0]["measurements"]["worst_case"] = m(5, 0)
        expect(baseline).to include('<td class="num">1,000</td><td class="num">timed out</td>')
      end
    end

    it "describes a candidate with several indexes, and one whose index definition is missing" do
      payload["labels"][0]["indexes"] = %w[quaack_a quaack_b]
      expect(ranking)
        .to include("<td>Your query with new indexes on #{sq("public.t (created_at)")} and " \
                    "#{sq("public.t (a, b)")}</td>")
      payload["indexes"]["quaack_a"]["ddl"] = nil
      payload["labels"][0]["indexes"] = %w[quaack_a]
      expect(section(render(payload), "ranking"))
        .to include("<td>Your query with a new index QUAACK couldn&#39;t describe (#{sq("quaack_a")})</td>")
    end

    it "sets apart the whole definition of an index it can't take apart" do
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE UNIQUE INDEX ON public.t (created_at)"
      expect(ranking).to include("Your query with a new index on #{sq("CREATE UNIQUE INDEX ON public.t (created_at)")}")
    end

    it "names an index's method when it isn't a btree, and keeps its predicate" do
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.t USING brin (created_at) WHERE a < ?"
      expect(ranking).to include("Your query with a new index on #{sq("public.t (created_at) WHERE a &lt; ?")} (brin)")
    end

    describe "what was measured and not ranked" do
      let(:unranked) { ranking[%r{<table id="not-ranked">.*?</table>}m] }

      def rows(html = unranked) = html.to_s.scan(%r{<tr>(.*?)</tr>}m).flatten.drop(1)

      def rule = "Made by QUAACK&#39;s own rewrite rule key_in_self_join"

      # A row of the table: what it was, who proposed it, and why it wasn't ranked.
      def row(what, why, who: rule)
        "<tr><td>#{what}</td>#{who ? "<td>#{who}</td>" : '<td class="missing">not recorded</td>'}<td>#{why}</td></tr>"
      end

      it "is a table behind a collapsed section, with a row each for what it was, who proposed it, and why" do
        collapsed = ranking[%r{<details class="not-ranked">\s*<summary>(.*?)</summary>(.*?)</details>}m, 0]
        expect(collapsed).to include("<summary>Show the 1 thing QUAACK tried that didn't pan out</summary>")
        expect(collapsed).to include(unranked)
        expect(ranking).not_to match(/<details[^>]*\bopen\b/)
        expect(unranked).to include(%(<thead><tr><th scope="col">What it was</th><th scope="col">Who proposed it</th>) +
                                    %(<th scope="col">Why it didn't make the cut</th></tr></thead>))
        expect(rows).to eq(
          ["<td>Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}</td>" \
           "<td>Made by QUAACK&#39;s own rewrite rule " \
           "key_in_self_join</td><td>Read 7,777 blocks on the slow values, against 1,000 for your query as it is, " \
           "which isn&#39;t more than 5% fewer.</td>"]
        )
      end

      it "names the source of a rewrite, and says who thought of your query's indexes isn't recorded" do
        payload["rewrites"].first["source"] = "llm"
        payload["excluded"]["original:top:1"] = "footprint_tie"
        payload["top"].pop
        expect(rows.map { it.scan(%r{<td[^>]*>(.*?)</td>}).flatten[1] })
          .to eq(["Suggested by the LLM", "not recorded"])
        expect(unranked).to include('<td class="missing">not recorded</td>')
        expect(section(render(payload), "ranking")).to include(
          "Who proposed it is who proposed the rewrite. QUAACK doesn't record who thought of each index"
        )
        payload["excluded"] = { "rewrite_1:top:1" => "not_better", "rewrite_1:none" => "below_top_three" }
        payload["top"] = [payload["top"].first.merge("label" => "original:top:1")]
        expect(section(render(payload), "ranking"))
          .to include("<summary>Show the 2 things QUAACK tried that didn't pan out</summary>")
      end

      it "says in words, with the numbers, that a candidate wasn't enough better on the slow values" do
        expect(unranked).to include(
          row("Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}",
              "Read 7,777 blocks on the slow values, against 1,000 for your query as it is, which isn&#39;t more " \
              "than 5% fewer.")
        )
      end

      it "says which other values a candidate was worse on, when it was better on the slow ones" do
        payload["labels"][2].merge!("measurements" => { "slow" => m(500, 1), "typical" => m(900, 1) },
                                    "verdicts" => { "slow" => "better", "typical" => "worse" })
        expect(unranked).to include(
          row("Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}",
              "Read fewer blocks on the slow values (500, against 1,000), but read 900 on the typical values, " \
              "against 200 for your query as it is, which is more than 5% more.")
        )
      end

      it "says a candidate lost a tie on index size, fell outside the top three, or was dropped on real data" do
        payload["excluded"] = { "rewrite_1:top:1" => "footprint_tie" }
        expect(unranked).to include("(a, b)</code></td><td>#{rule}</td><td>Beat your query as it is, but tied with a " \
                                    "candidate whose new indexes take less disk space.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "below_top_three" }
        expect(section(render(payload), "ranking")).to include("<td>Beat your query as it is, but three other " \
                                                               "candidates did better.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "result_mismatch" }
        expect(section(render(payload), "ranking"))
          .to include("<td>Was dropped when QUAACK compared the rewrite&#39;s results with your query&#39;s on " \
                      "the real data. See rewrite Vivid Cove under the queries.</td></tr>")
      end

      it "says a candidate's measurement timed out" do
        payload["labels"] << { "label" => "rewrite_1:top:2", "search" => "rewrite_1", "indexes" => ["quaack_a"],
                               "timed_out" => true, "measurements" => nil, "verdicts" => nil }
        expect(unranked).to include(row("Rewrite Vivid Cove with a new index on #{sq("public.t (created_at)")}",
                                        "Timed out while QUAACK measured it."))
      end

      it "lists a label once, by why it was left out, when one of its sets also timed out" do
        payload["labels"][2]["timed_out"] = true
        expect(rows.size).to eq(1)
        expect(unranked).not_to include("imed out while")
      end

      it "gives no numbers it doesn't have" do
        payload["labels"].delete_at(2)
        expect(unranked)
          .to include(row("Rewrite Vivid Cove with new indexes", "Was no better than your query as it is."))
      end

      it "is left out when everything measured is ranked" do
        payload["excluded"] = {}
        expect(ranking).not_to include("not-ranked")
      end
    end

    it "says there's no ranking when nothing beat the original, and still says how each candidate measured" do
      ranking = section(render(negative_payload), "ranking")
      expect(ranking).to include("Nothing beat your query as it is, so there is no ranking.")
      expect(ranking.sub(%r{<details class="not-ranked">.*?</details>}m, "")).not_to include("<tr")
      expect(ranking).to include("<tr><td>Your query with a new index on #{sq("public.t (created_at)")}</td>" \
                                 '<td class="missing">not recorded</td><td>Read 990 blocks on the ' \
                                 "slow values, against 1,000 for your query as it is, which isn&#39;t more than " \
                                 "5% fewer.</td></tr>")
    end

    describe "each ranked candidate" do
      def candidate(rank) = ranking.scan(%r{<article class="candidate">.*?</article>}m)[rank - 1]

      it "has its own block, in rank order, and no unranked candidate has one" do
        expect(ranking.scan(%r{<article class="candidate"><h3>(.*?)</h3>}))
          .to eq([["1. Rewrite Vivid Cove with no new indexes"],
                  ["2. Your query with a new index on #{sq("public.t (created_at)")}"]])
        expect(ranking.scan("<article").size).to eq(2)
      end

      it "shows blocks per set of values, against the original's, with memory and disk, verdict, and stability" do
        expect(candidate(1)).to include(
          '<tr><td>slow</td><td class="num">300</td><td class="num">1,000</td><td class="num">30</td>' \
          '<td class="num">270</td><td>70% fewer blocks</td><td>unstable: the count changed between runs</td></tr>'
        )
        expect(candidate(2)).to include(
          '<tr><td>typical</td><td class="num">190</td><td class="num">200</td><td class="num">190</td>' \
          '<td class="num">0</td><td>5% fewer blocks</td><td></td></tr>'
        )
      end

      describe "against your query" do
        def against(ours, theirs, verdict: "no_worse")
          payload["labels"][0].merge!("measurements" => { "slow" => m(400, 300), "typical" => ours },
                                      "verdicts" => { "slow" => "better", "typical" => verdict })
          payload["original_measurements"]["typical"] = theirs
          typical(section(render(payload), "ranking").scan(%r{<article class="candidate">.*?</article>}m)[1])
        end

        # A candidate's typical row's against-your-query cell.
        def typical(candidate)
          candidate[%r{<tr><td>typical</td>(?:<td class="num">[^<]*</td>)*<td>([^<]*)</td>}, 1]
        end

        it "says how many percent more or fewer blocks it read, from the two numbers in its row" do
          expect(against(m(48, 0), m(100, 0), verdict: "better")).to eq("52% fewer blocks")
          expect(against(m(104, 0), m(100, 0))).to eq("4% more blocks")
          expect(against(m(1668, 0), m(3454, 0), verdict: "better")).to eq("52% fewer blocks")
        end

        it "says same when the two are equal, and under 1% or over 99% when rounding would hide a difference" do
          expect(against(m(200, 0), m(200, 0))).to eq("same")
          expect(against(m(0, 0), m(0, 0))).to eq("same")
          expect(against(m(999, 0), m(1000, 0))).to eq("under 1% fewer blocks")
          expect(against(m(1001, 0), m(1000, 0))).to eq("under 1% more blocks")
          expect(against(m(12, 0), m(5120, 0), verdict: "better")).to eq("over 99% fewer blocks")
          expect(against(m(51, 0), m(5120, 0), verdict: "better")).to eq("99% fewer blocks")
          expect(against(m(0, 0), m(5120, 0), verdict: "better")).to eq("100% fewer blocks")
          expect(against(m(200, 0), m(100, 0), verdict: "worse")).to eq("100% more blocks")
        end

        it "counts the blocks when your query read none, since there's no percentage of zero" do
          expect(against(m(5, 0), m(0, 0), verdict: "worse")).to eq("5 more blocks")
          expect(against(m(1, 0), m(0, 0), verdict: "worse")).to eq("1 more block")
        end

        it "keeps the verdict word only where a number is missing or timed out" do
          expect(against(m(5, 0), { "timed_out" => true }, verdict: "better")).to eq("better")
          expect(against({ "timed_out" => true }, m(5, 0), verdict: "worse")).to eq("worse")
          expect(against(m(5, 0), nil, verdict: "no_worse")).to eq("no worse")
          expect(against({ "timed_out" => false }, m(5, 0), verdict: "no_worse")).to eq("no worse")
          expect(against(m(5, 0), nil, verdict: nil)).to eq("not recorded")
        end
      end

      it "says a set of values timed out" do
        payload["labels"][0]["measurements"]["worst_case"] = { "timed_out" => true }
        payload["labels"][0]["verdicts"]["worst_case"] = "worse"
        expect(candidate(2)).to include('<tr><td>worst case</td><td class="num">timed out</td>' \
                                        '<td class="num">not recorded</td>')
      end

      it "lists the indexes it ran with, as DDL, and points a rewrite at its SQL" do
        expect(candidate(2)).to include("<li>#{sq("CREATE INDEX ON public.t USING btree (created_at)")}</li>")
        expect(candidate(1)).not_to include("CREATE INDEX")
        expect(candidate(1)).to include('Its SQL is under <a href="#rewrite-1">rewrite Vivid Cove</a>, above.')
        expect(candidate(2)).not_to include("<a ")
      end
    end
  end

  describe "why the winner reads fewer blocks" do
    let(:explanation) { section(html, "explanation") }

    # A plan node as the payload sends it.
    def pnode(type, depth, **shape)
      shape = { relation: nil, index: nil, est: 10, actual: 10, selectivity: nil }.merge(shape)
      { "node" => type, "relation" => shape[:relation], "index" => shape[:index], "est_rows" => shape[:est],
        "actual_rows" => shape[:actual], "selectivity" => shape[:selectivity], "depth" => depth }
    end

    # Each plan table in the section, by its rows.
    def plan_rows(html) = html.scan(%r{<table class="plan">.*?</table>}m).map { it.scan(%r{<tr.*?</tr>}m).drop(1) }

    let(:header) do
      '<tr><th scope="col">Step</th><th scope="col">Table</th><th scope="col">Index</th>' \
        '<th scope="col" class="num">Estimated rows</th><th scope="col" class="num">Actual rows</th>' \
        '<th scope="col" class="num">Share of the table</th></tr>'
    end

    it "explains the winner from blocks, with each plan as a table of its steps" do
      expect(explanation).to include("Rewrite Vivid Cove with no new indexes read 300 blocks on the slow values, " \
                                     "against 1,000 for your query as it is (70% fewer).")
      expect(explanation).to include("<p>How it runs rewrite Vivid Cove with no new indexes:</p>")
      expect(explanation.scan(header).size).to eq(2)
      expect(plan_rows(explanation)).to eq(
        [[[%(<tr class="differs"><td class="step" style="padding-left: 0.65rem">Seq Scan ),
           %(<strong class="mark">differs</strong></td><td>#{sq("public.t")}</td><td></td><td class="num">50</td>),
           %(<td class="num">50</td><td class="num">5.0%</td></tr>)].join],
         [[%(<tr class="differs"><td class="step" style="padding-left: 0.65rem">Index Scan ),
           %(<strong class="mark">differs</strong></td><td>#{sq("public.t")}</td><td>#{sq("t_a_idx")}</td>),
           %(<td class="num">5</td><td class="num">5</td><td class="num">0.5%</td></tr>)].join]]
      )
      expect(explanation).not_to include("<li>")
    end

    context "with plans that share some of their steps" do
      before do
        payload["original_plan"] = [pnode("Limit", 0), pnode("Nested Loop", 1),
                                    pnode("Seq Scan", 2, relation: "public.t", est: 9_000, actual: 12_345,
                                                         selectivity: 0.5),
                                    pnode("Index Scan", 2, relation: "public.u", index: "u_pkey", est: 1, actual: 1)]
        payload["rewrites"].first["plan"] = [pnode("Limit", 0), pnode("Nested Loop", 1),
                                             pnode("Index Scan", 2, relation: "public.t", index: "t_a_idx"),
                                             pnode("Index Scan", 2, relation: "public.u", index: "u_pkey")]
      end

      it "indents each step by its depth, under an arrow, and marks only the steps the plans don't share" do
        original, rewrite = plan_rows(explanation)
        expect(original).to eq(
          [[%(<tr><td class="step" style="padding-left: 0.65rem">Limit</td><td></td><td></td>),
            %(<td class="num">10</td><td class="num">10</td><td class="num"></td></tr>)].join,
           [%(<tr><td class="step" style="padding-left: 2.15rem"><span class="arrow" aria-hidden="true">-&gt; </span>),
            %(Nested Loop</td><td></td><td></td><td class="num">10</td><td class="num">10</td>),
            %(<td class="num"></td></tr>)].join,
           [%(<tr class="differs"><td class="step" style="padding-left: 3.65rem"><span class="arrow" ),
            %(aria-hidden="true">-&gt; </span>Seq Scan <strong class="mark">differs</strong></td>),
            %(<td>#{sq("public.t")}</td><td></td><td class="num">9,000</td><td class="num">12,345</td>),
            %(<td class="num">50.0%</td></tr>)].join,
           [%(<tr><td class="step" style="padding-left: 3.65rem"><span class="arrow" aria-hidden="true">-&gt; </span>),
            %(Index Scan</td><td>#{sq("public.u")}</td><td>#{sq("u_pkey")}</td><td class="num">1</td>),
            %(<td class="num">1</td><td class="num"></td></tr>)].join]
        )
        expect(rewrite.map { it.include?("differs") }).to eq([false, false, true, false])
        expect(rewrite[2]).to include("<td>#{sq("t_a_idx")}</td>")
      end

      it "says what a marked step is" do
        expect(explanation).to include(
          "<p class=\"note\">A step marked “differs”, and shaded, is one the other plan doesn&#39;t have in " \
          "the same place.</p>"
        )
      end

      it "doesn't mark a step that uses another index as shared" do
        payload["rewrites"].first["plan"][3]["index"] = "u_other_idx"
        expect(plan_rows(explanation).first.map { it.include?("differs") }).to eq([false, false, true, true])
      end

      it "doesn't mark a step on another table as shared" do
        payload["rewrites"].first["plan"][3]["relation"] = "public.v"
        expect(plan_rows(explanation).first.map { it.include?("differs") }).to eq([false, false, true, true])
      end

      it "marks only a step one plan adds, not the steps under it that both plans have" do
        payload["original_plan"].insert(1, pnode("Sort", 1))
        payload["original_plan"][2..].each { it["depth"] += 1 }
        original, rewrite = plan_rows(explanation)
        expect(original.map { it.include?("differs") }).to eq([false, true, false, true, false])
        expect(rewrite.map { it.include?("differs") }).to eq([false, false, true, false])
      end
    end

    it "marks nothing, and says nothing of marks, when the plans have the same steps" do
      payload["rewrites"].first["plan"] = payload["original_plan"].map(&:dup)
      expect(explanation).not_to include("differs")
      expect(explanation).not_to include('class="note"')
    end

    it "says one row, a share too small to round, and a row count it doesn't have" do
      payload["original_plan"] = [pnode("Index Scan", 0, relation: "public.t", index: "t_pkey", est: 1, actual: 1,
                                                         selectivity: 0.000001),
                                  pnode("Limit", 1, est: 12_345, actual: nil)]
      rows = plan_rows(explanation).first
      expect(rows.first).to include(%(<td class="num">1</td><td class="num">1</td><td class="num">under 0.1%</td>))
      expect(rows.last).to include(%(<td class="num">12,345</td><td class="missing">not recorded</td>))
    end

    it "lays out a plan from a payload without depths as a flat table" do
      payload["original_plan"] = [pnode("Limit", nil), pnode("Seq Scan", nil, relation: "public.t")]
      expect(plan_rows(explanation).first).to eq(
        [[%(<tr class="differs"><td class="step">Limit <strong class="mark">differs</strong></td><td></td><td></td>),
          %(<td class="num">10</td><td class="num">10</td><td class="num"></td></tr>)].join,
         [%(<tr class="differs"><td class="step">Seq Scan <strong class="mark">differs</strong></td>),
          %(<td>#{sq("public.t")}</td><td></td><td class="num">10</td><td class="num">10</td>),
          %(<td class="num"></td></tr>)].join]
      )
    end

    it "lays out a plan flat when any depth isn't a whole number from zero up" do
      [["2; color: red", 0], [-1, 0], [1.5, 0], [0, nil]].each do |a, b|
        payload["original_plan"] = [pnode("Limit", a), pnode("Seq Scan", b)]
        expect(plan_rows(section(render(payload), "explanation")).first)
          .to all(satisfy { it.include?('<td class="step">') && !it.include?("style") && !it.include?("arrow") })
      end
    end

    it "says the winner's plan wasn't recorded when the winner is the original query with new indexes" do
      payload["top"].reverse!
      expect(explanation).to include("The plan with the new indexes: not recorded.")
      expect(explanation).not_to include("t_a_idx")
      expect(plan_rows(explanation).size).to eq(1)
      expect(explanation).not_to include("differs")
    end

    it "is left out when nothing beat the original" do
      expect(render(negative_payload)).not_to include('id="explanation"')
    end
  end

  describe "the index table" do
    let(:indexes) { section(html, "indexes") }

    it "lists the ranked candidates' indexes as proposed, and the rest as built and measured" do
      other = "<h3>Other indexes QUAACK built and measured</h3>"
      expect(indexes).to match(%r{<h2>Proposed indexes</h2>.*btree \(created_at\).*#{other}.*btree \(a, b\)}m)
      expect(indexes.scan("<table").size).to eq(2)
    end

    it "gives each index its size, and each existing index it overlaps with its size, in the last two columns" do
      expect(indexes).to include(
        "<tr><td>#{sq("CREATE INDEX ON public.t USING btree (created_at)")}</td><td class=\"num\">8 kB</td>" \
        "<td>#{sq("t_created_at_id_idx")} (40 kB)</td><td>none</td></tr>"
      )
      expect(indexes).to include('<td class="num">16 kB</td><td>none</td>' \
                                 "<td>#{sq("t_a_idx")} (8 kB)<br>#{sq("t_a_b_idx")} (size not recorded)</td></tr>")
    end

    it "uses the unit that fits, with thousands separators" do
      sizes = { 1_024_000 => "1,000 kB", 54_456 * 1024 => "53.2 MB", 313_776 * 1024 => "306.4 MB",
                12_687_440 * 1024 => "12.1 GB", 2_000_000 * 1024 * 1024 => "1,953.1 GB", 0 => "0 kB" }
      sizes.each do |bytes, text|
        payload["indexes"]["quaack_a"]["size"] = bytes
        expect(section(render(payload), "indexes")).to include(%(<td class="num">#{text}</td>))
      end
    end

    it "lists only the indexes the payload carries, whatever a label names" do
      payload["labels"][0]["indexes"] = %w[quaack_a quaack_gone]
      expect(indexes.scan("<tr><td>").size).to eq(2)
      expect(indexes).not_to include("quaack_gone")
    end

    it "says so when a size wasn't recorded" do
      payload["indexes"]["quaack_a"]["size"] = nil
      expect(indexes).to include('</code></td><td class="num">not recorded</td>')
    end

    it "says so when the enclave couldn't parse a built index's DDL" do
      payload["indexes"]["quaack_b"]["ddl"] = nil
      expect(indexes).to include(esc("<tr><td>#{sq("quaack_b")} (QUAACK couldn't read this index's definition " \
                                     "back)</td>" \
                                     '<td class="num">16 kB</td>'))
    end

    it "calls a negative result's table what it is, not proposed indexes" do
      indexes = section(render(negative_payload), "indexes")
      expect(indexes).to include("<h2>Indexes QUAACK built and measured</h2>")
      expect(indexes).to include("btree (created_at)").and include("btree (a, b)")
      expect(render(negative_payload)).not_to match(/Proposed indexes|Other indexes/)
    end
  end

  describe "a rule-made rewrite that a test disproved (rewrite-rules)" do
    let(:bugs) do
      [{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"], "step" => "rewrite-test" },
       { "rewrite" => "rewrite_3", "rules" => %w[or_to_union key_in_self_join], "step" => "counterexamples" },
       { "rewrite" => "rewrite_4", "rules" => ["<b>"], "step" => "result-comparison" }]
    end
    let(:bug_html) { render(payload.merge("rule_bugs" => bugs)) }
    let(:bug_section) { section(bug_html, "quaack-bugs") }

    it "says so first, above everything else, as a bug in QUAACK" do
      expect(bug_html.scan(/<section id="([a-z-]+)">/).flatten.first(2)).to eq(%w[quaack-bugs summary])
      expect(bug_section).to include("<h2>QUAACK bug: a rule made a wrong rewrite</h2>")
      expect(bug_section).to include("a rule has a bug")
    end

    it "names each rewrite, the rules that made it, and the test that proved it wrong" do
      expect(bug_section).to include(esc("<li>Rewrite Smooth Kayak, made by QUAACK's own rewrite rule " \
                                         "key_in_self_join, returned different results on made-up test data.</li>"))
      expect(bug_section).to include(esc("<li>Rewrite Dainty Bloom, made by QUAACK's own rewrite rules " \
                                         "or_to_union, then key_in_self_join, returned different results on test " \
                                         "data the LLM wrote to break it.</li>"))
      expect(bug_section).to include(esc("<li>Rewrite Odd Mitten, made by QUAACK's own rewrite rule &lt;b&gt;, " \
                                         "returned different results on the real data.</li>"))
      expect(bug_section).not_to include("<b>")
    end

    it "is left out when no rule-made rewrite was disproved, or the enclave sent no list" do
      expect(render(payload.merge("rule_bugs" => []))).not_to include('id="quaack-bugs"')
      expect(html).not_to include('id="quaack-bugs"')
    end
  end

  describe "when nothing beat the original (negative-result)" do
    let(:rewrites) do
      [fated(2, "rewrite_test_disproved", scenario: "s3", rule: "multiset"),
       fated(3, "counterexamples_disproved", round: 2, rule: "row_count", source: "llm"),
       fated(5, "not_better", source: "rule", rules: ["key_in_self_join"]),
       fated(7, "same_plans", source: "operator"),
       fated(8, "rewrite_test_failed", scenario: "s0", rule: "unsupported_order")]
    end

    let(:negative_html) { render(negative_payload.merge("rewrites" => rewrites)) }
    let(:why) { section(negative_html, "negative-result") }

    it "comes after the ranking, and only when nothing was ranked" do
      expect(negative_html.scan(/<section id="([a-z-]+)">/).flatten)
        .to eq(%w[summary queries ranking negative-result indexes accountability burndown])
      expect(html).not_to include("negative-result")
    end

    it "says what became of every rewrite, with its source, in words" do
      list = why[%r{<ul id="negative-rewrites">.*?</ul>}m]
      expect(list.scan(/<li>(Rewrite [^(]+) \(/).flatten)
        .to eq(["Rewrite Smooth Kayak", "Rewrite Dainty Bloom", "Rewrite Bright Island", "Rewrite Trim Falcon",
                "Rewrite Wise Slipper"])
      expect(list).to include(esc("<li>Rewrite Smooth Kayak (source not recorded): It returned different results " \
                                  "from your query on made-up test data (duplicate join keys), so it's wrong.</li>"))
      expect(list).to include("<li>Rewrite Dainty Bloom (suggested by the LLM): It returned different results")
      expect(list)
        .to include(esc("<li>Rewrite Bright Island (made by QUAACK's own rewrite rule key_in_self_join): It passed"))
      expect(list).to include("<li>Rewrite Trim Falcon (your own rewrite): Postgres plans it exactly as")
      expect(list).to include("<li>Rewrite Wise Slipper (source not recorded): A test on made-up data (empty tables) " \
                              "ended without comparing results")
    end

    it "says so when no rewrite was kept" do
      expect(section(render(negative_payload.merge("rewrites" => [])), "negative-result"))
        .to include("QUAACK kept no rewrite to test.")
    end

    it "says which indexes the planner wouldn't use, and why, once each, with the queries they were tried for" do
      table = why[%r{<table id="declined-indexes">.*?</table>}m]
      expect(table).to include("<tr><td>#{sq("CREATE INDEX ON public.t USING btree (a) WHERE a &lt; ?")}</td>" \
                               "<td>your query, rewrite Vivid Cove</td><td>The planner never chose it.</td></tr>")
      expect(table).to include(esc("<tr><td>#{sq("CREATE INDEX ON public.t USING gin (b)")}</td>" \
                                   "<td>rewrite Vivid Cove</td><td>HypoPG, which QUAACK uses to try an index " \
                                   "without building it, couldn't create it (Postgres error code 0A000).</td></tr>"))
      expect(table).to include(esc("<tr><td>an index QUAACK couldn't write out</td><td>your query</td>" \
                                   "<td>QUAACK couldn't write its definition.</td></tr>"))
    end

    it "leaves out an error code the payload doesn't have, with no empty brackets" do
      negative["declined"][1]["sqlstate"] = nil
      expect(why).to include(esc("without building it, couldn't create it.</td>"))
    end

    it "says a decline's reason wasn't recorded when the payload has none" do
      negative["declined"] = [{ "ddl" => "CREATE INDEX ON public.t USING btree (z)", "reason" => nil,
                                "sqlstate" => nil, "searches" => ["original"] }]
      expect(why).to include("<td>your query</td><td>not recorded</td></tr>")
    end

    it "says which suggested indexes already existed, with the existing index and its size" do
      table = why[%r{<table id="existing-indexes">.*?</table>}m]
      expect(table).to include("<tr><td>#{sq("CREATE INDEX ON public.t USING btree (c)")}</td>" \
                               "<td>your query, rewrite Smooth Kayak</td><td>#{sq("t_c_d_idx")}</td>" \
                               '<td class="num">3.0 MB</td></tr>')
    end

    it "says none when no index was declined or already existed" do
      negative.merge!("declined" => [], "existing" => [])
      expect(why).to include("The planner would have used every index QUAACK thought of.")
      expect(why).to include("None of the indexes QUAACK thought of already existed.")
      expect(why).not_to include("<table")
    end
  end

  describe "who proposed what" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    def rows(html, id)
      table = html[%r{<table id="accountability-#{id}">.*?</table>}m]
      table.scan(%r{<tr><th scope="row">(.*?)</th>(.*?)</tr>})
           .to_h { |name, cells| [name, cells.scan(%r{<td[^>]*>(.*?)</td>}).flatten] }
    end

    let(:rewrites) do
      [fated(1, "ranked", source: "rule", rules: ["key_in_self_join"]),
       fated(2, "same_plans", source: "llm"), fated(3, "rewrite_test_disproved", source: "llm"),
       fated(4, "counterexamples_disproved", source: "llm"), fated(5, "production_mismatch", source: "llm"),
       fated(6, "not_better", source: "llm"), fated(7, "rewrite_test_failed", source: "llm"),
       fated(8, "footprint_tie", source: "operator"), fated(9, "unfinished", source: "operator")]
    end

    let(:stages) do
      { "rewrite-rules" => { "rewrites" => rec(0, 1, added: { "key_in_self_join" => 3 },
                                                     dropped: { "duplicate" => 1, "over_cap" => 0,
                                                                "failed_checks" => 1 }) },
        "llm-rewrites" => { "rewrites" => rec(0, 6, added: { "llm" => 8 }, dropped: { "inbound_check" => 2 }) } }
    end

    let(:accountable) do
      render(payload.merge("rewrites" => rewrites, "burndown" => { "stages" => stages, "totals" => {} }))
    end

    it "has one rewrites table: a row per source, a column per outcome" do
      table = accountable[%r{<table id="accountability-rewrites">.*?</table>}m]
      expect(table.scan(%r{<th scope="col"[^>]*>(.*?)</th>}).flatten)
        .to eq(["Source", "Proposed", "Refused on arrival", "Same plan as the original", "Wrong results",
                "Not better", "Ranked", "Stopped for another reason"])
      expect(rows(accountable, "rewrites").keys).to eq([esc("QUAACK's own rules"), "The LLM", "You"])
    end

    it "counts each source's rewrites by what became of them" do
      counted = rows(accountable, "rewrites")
      expect(counted[esc("QUAACK's own rules")]).to eq(%w[3 2 0 0 0 1 0])
      expect(counted["The LLM"]).to eq(%w[8 2 1 3 1 0 1])
    end

    it "never counts a failed, tied, or unfinished rewrite as wrong or not better" do
      expect(rows(accountable, "rewrites")["You"].last(5)).to eq(%w[0 0 0 0 2])
    end

    it "says not recorded, never zero, for proposals and refusals the burndown doesn't count" do
      expect(rows(accountable, "rewrites")["You"].first(2)).to eq(["not recorded", "not recorded"])
      expect(rows(html, "rewrites")[esc("QUAACK's own rules")]).to eq(["not recorded", "not recorded", "0", "0",
                                                                       "0", "1", "0"])
      expect(html).to include("&ldquo;Not recorded&rdquo; means this run didn't count it. It doesn't mean none.")
    end

    it "says not recorded when the recorded proposals are fewer than the rewrites kept" do
      stages["llm-rewrites"]["rewrites"] = rec(0, 1, added: { "llm" => 1 })
      expect(rows(accountable, "rewrites")["The LLM"].first(2)).to eq(["1", "not recorded"])
    end

    it "adds a row for rewrites whose source the payload doesn't say, only when there are some" do
      expect(rows(accountable, "rewrites").keys).not_to include("Source not recorded")
      unsourced = render(payload.merge("rewrites" => rewrites + [fated(10, "not_better")]))
      expect(rows(unsourced, "rewrites")["Source not recorded"])
        .to eq(["not recorded", "not recorded", "0", "0", "1", "0", "0"])
    end

    describe "the index table" do
      it "has a row per source and one for all of them, and a column per outcome" do
        table = html[%r{<table id="accountability-indexes">.*?</table>}m]
        expect(table.scan(%r{<th scope="col"[^>]*>(.*?)</th>}).flatten)
          .to eq(["Source", "Proposed", "Already existed", "Planner ignored", "Built and measured", "Not better",
                  "Ranked"])
        expect(rows(html, "indexes").keys)
          .to eq(["Generator one, from the query&#39;s text", "Generator two, from the query&#39;s plan", "The LLM",
                  "All sources together"])
      end

      it "says not recorded for every count by source that the payload doesn't carry" do
        missing = ["not recorded"] * 6
        expect(rows(html, "indexes").values.first(3)).to eq([missing, missing, missing])
      end

      it "counts what the payload does carry, for all sources together: built, ranked, and not" do
        expect(rows(html, "indexes")["All sources together"])
          .to eq(["not recorded", "not recorded", "not recorded", "2", "1", "1"])
      end

      describe "the not better column" do
        # Built, not better, ranked, for all sources. quaack_a is ranked.
        # quaack_b ran only in rewrite_1:top:1, and in other if it's given.
        def built(reason, other = nil)
          second = payload["labels"][2].merge("label" => "original:top:2", "search" => "original")
          changed = payload.merge("excluded" => { "rewrite_1:top:1" => reason, "original:top:2" => other }.compact,
                                  "labels" => payload["labels"] + (other ? [second] : []))
          rows(render(changed), "indexes")["All sources together"].last(3)
        end

        it "counts an index whose every label was not better" do
          expect(built("not_better")).to eq(%w[2 1 1])
          expect(built("not_better", "not_better")).to eq(%w[2 1 1])
        end

        it "doesn't count an index whose only label beat the query and tied on index size" do
          expect(built("footprint_tie")).to eq(%w[2 0 1])
        end

        it "doesn't count an index whose only label beat the query and fell below the top three" do
          expect(built("below_top_three")).to eq(%w[2 0 1])
        end

        it "doesn't count an index whose only label timed out and was never judged" do
          payload["labels"][2].merge!("timed_out" => true, "measurements" => nil, "verdicts" => nil)
          expect(built(nil)).to eq(%w[2 0 1])
        end

        it "doesn't count an index with mixed labels: one not better, one that beat the query" do
          expect(built("not_better", "footprint_tie")).to eq(%w[2 0 1])
          expect(built("below_top_three", "not_better")).to eq(%w[2 0 1])
        end

        it "doesn't count a built index that no measured label ran with" do
          payload["indexes"]["quaack_c"] = payload["indexes"]["quaack_b"]
          expect(built("not_better")).to eq(%w[3 1 1])
        end

        it "says under the table why the last two columns needn't add up to the built ones" do
          expect(section(html, "accountability")).to include(
            "An index counts as not better only if no candidate that ran with it beat your query. A built index " \
            "whose candidate beat your query and still wasn't ranked (it tied with a smaller one, or three others " \
            "did better), or whose candidate timed out, is counted only under built and measured."
          )
        end
      end

      it "counts the declined and existing indexes of a negative result" do
        expect(rows(render(negative_payload), "indexes")["All sources together"])
          .to eq(["not recorded", "1", "3", "2", "2", "0"])
      end

      it "fills in each source's proposals, and the LLM's drops, once the burndown records them" do
        stages.merge!(
          "index-from-query" => { "original" => rec(0, 3, added: { "generator_one" => 3 }),
                                  "rewrite_1" => rec(0, 2, added: { "generator_one" => 2 }) },
          "index-from-plan" => { "original" => rec(0, 4, added: { "generator_two" => 4 }) },
          "llm-index-ideas" => { "original" => rec(0, 1, added: { "llm" => 5 },
                                                         dropped: { "covered_by_existing" => 1, "duplicate" => 1,
                                                                    "never_used" => 1, "hypopg_refused" => 1 }) },
          "llm-index-refine" => { "original" => rec(0, 0, added: { "llm" => 1 }, dropped: { "never_used" => 1 }) }
        )
        counted = rows(accountable, "indexes")
        expect(counted["Generator one, from the query&#39;s text"]).to eq(["5"] + (["not recorded"] * 5))
        expect(counted["Generator two, from the query&#39;s plan"]).to eq(["4"] + (["not recorded"] * 5))
        expect(counted["The LLM"]).to eq(["6", "1", "3", "not recorded", "not recorded", "not recorded"])
        expect(counted["All sources together"].first).to eq("15")
      end
    end
  end

  describe "the burndown" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    def row(name, *cells)
      added, dropped, extra = cells.values_at(1, 2, 5)
      %(<tr><th scope="row">#{esc(name)}</th><td class="num">#{cells[0]}</td><td>#{added}</td><td>#{dropped}</td>) +
        %(<td class="num">#{cells[3]}</td><td class="num">#{cells[4]}</td><td>#{extra}</td></tr>)
    end

    let(:burndown) do
      { "stages" => {
          "index-from-query" => { "original" => rec(0, 3, added: { "generator_one" => 3 }) },
          "index-dedupe" => { "original" => rec(4, 3, dropped: { "duplicate" => 1 }),
                              "rewrite_1" => rec(2, 1, dropped: { "covered_by_existing" => 1 }),
                              "rewrite_2" => rec(3, 1, dropped: { "covered_by_existing" => 1 }, set_aside: 1) },
          "plan-pruning" => { "rewrites" => rec(2, 1, dropped: { "inbound_check" => 0, "failed_to_plan" => 0,
                                                                 "output_mismatch" => 0, "same_plans" => 1 }) },
          "rewrite-test" => { "rewrites" => rec(2, 1, dropped: { "s3" => 1 }, extra: { "untested_atoms" => 2 }) },
          "rewrite-rules" => { "rewrites" => rec(0, 1, added: { "key_in_self_join" => 2 },
                                                       dropped: { "duplicate" => 1, "over_cap" => 0,
                                                                  "failed_checks" => 0 }) }
        },
        "totals" => { "hypothetical_explains" => 1234, "fixture_loads" => 3 } }
    end

    let(:llm_calls) do
      { "llm-index-ideas" => 2, "llm-index-refine" => 1, "llm-rewrites" => 1, "operator-rewrites" => 1,
        "llm-counterexamples" => 3, "rewrite-llm-index-ideas" => 4, "rewrite-llm-index-refine" => 2 }
    end
    let(:burndown_section) { section(render(payload.merge("burndown" => burndown), llm_calls:), "burndown") }
    let(:index_table) { burndown_section[%r{<table id="burndown-index">.*?</table>}m] }
    let(:rewrite_table) { burndown_section[%r{<table id="burndown-rewrite">.*?</table>}m] }

    it "names the columns in words" do
      expect(index_table.scan(%r{<th scope="col"[^>]*>(.*?)</th>}).flatten)
        .to eq(["Stage", "Came in", "Added", "Dropped", "Set aside", "Went on", "Also counted"])
    end

    it "shows the original's index ideas stage by stage, in words, drops by reason" do
      expect(index_table).to include(row("Ideas from the query's text", 0, "from the query&#39;s text: 3", "none", 0,
                                         3, "none"))
      expect(index_table).to include(row("Removing duplicates and indexes you already have", 4, "none",
                                         "the same as another idea: 1", 0, 3, "none"))
    end

    it "lists every stage, and says not recorded for one the run didn't count" do
      expect(index_table.scan(%r{<tr><th scope="row">(.*?)</th>}).flatten)
        .to eq(["Ideas from the query&#39;s text", "Ideas from the query&#39;s plan",
                "Removing duplicates and indexes you already have",
                "Asking the planner whether it would use each one", "Ideas from the LLM",
                "The LLM&#39;s second round of ideas", "Trying indexes together"])
      expect(index_table).to include('<tr><th scope="row">Ideas from the LLM</th>' \
                                     '<td colspan="6" class="missing">not recorded</td></tr>')
      expect(index_table.scan("not recorded").size).to eq(5)
    end

    it "shows the rewrite stages in words, in order, with their other counts" do
      expect(rewrite_table.scan(%r{<tr><th scope="row">(.*?)</th>}).flatten)
        .to eq(["Rewrites from QUAACK&#39;s own rules", "Rewrites from the LLM", "Your own rewrites",
                "Checking what each rewrite assumes", "Checking each rewrite can run differently from your query",
                "Testing on made-up edge-case data", "Testing on data the LLM wrote to break them",
                "Index ideas for the rewrites: removing duplicates and indexes you already have",
                "Choosing indexes for each rewrite", "Measuring on the real data and choosing"])
      expect(rewrite_table).to include(row("Testing on made-up edge-case data", 2, "none",
                                           "wrong on duplicate join keys: 1", 0, 1,
                                           "conditions the test data never exercised: 2"))
      expect(rewrite_table).to include('<tr><th scope="row">Rewrites from the LLM</th>' \
                                       '<td colspan="6" class="missing">not recorded</td></tr>')
    end

    it "puts the rewrite stages' own reasons and counts in words" do
      measured = { "production_mismatch" => 1, "production_timed_out" => 1, "production_not_compared" => 1,
                   "not_better" => 1, "measurement_timed_out" => 1, "footprint_tie" => 1, "below_top_three" => 1 }
      stages = { "llm-rewrites" => { "rewrites" => rec(0, 1, added: { "llm" => 3 },
                                                             dropped: { "too_many" => 1, "bad_assumption" => 1 }) },
                 "operator-rewrites" => { "rewrites" => rec(0, 1, added: { "operator" => 1 }) },
                 "assumption-check" => { "rewrites" => rec(2, 1, dropped: { "unmet_assumption" => 1 },
                                                                 extra: { "operator_warnings" => 2 }) },
                 "rewrite-test" => { "rewrite_1" => rec(1, 1, extra: { "vacuity_guard_retries" => 3 }) },
                 "counterexamples" => { "rewrite_1" => rec(2, 1, dropped: { "round_2" => 1 },
                                                                 extra: { "atoms_covered" => 1 }) },
                 "measurement" => { "rewrites" => rec(7, 0, dropped: measured,
                                                            extra: { "partial_comparisons" => 2 }) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")

      expect(table).to include(row("Rewrites from the LLM", 0, "from the LLM: 3",
                                   "over the limit of five: 1; assumed something QUAACK can&#39;t check: 1", 0, 1,
                                   "none"))
      expect(table).to include(row("Checking what each rewrite assumes", 2, "none",
                                   "assumed something your data doesn&#39;t hold: 1", 0, 1,
                                   "warnings on your own rewrites: 2"))
      expect(table).to include(row("Testing on made-up edge-case data", 1, "none", "none", 0, 1,
                                   "retries to make sure every condition mattered: 3"))
      expect(table).to include(row("Testing on data the LLM wrote to break them", 2, "none", "wrong in round 2: 1",
                                   0, 1, "untested conditions the LLM&#39;s data exercised: 1"))
      expect(table).to include(row("Measuring on the real data and choosing", 7, "none",
                                   "wrong on the real data: 1; timed out on the real data: 1; " \
                                   "couldn&#39;t be compared on the real data: 1; no better than your query: 1; " \
                                   "timed out in every measurement run: 1; lost a tie on index size: 1; " \
                                   "outside the top three: 1", 0, 0,
                                   "compared on only part of the real data: 2"))
    end

    # Task 20261001-20: the names the enclave's index stages record.
    it "puts the index stages' own reasons and counts in words" do
      refused = %w[unqualified_table unknown_relation unrepresentable unparsable not_create_index
                   forbidden_in_index unsupported_construct].to_h { [it, 1] }
      ranked = { "below_top_three" => 1, "combination_unused_index" => 2, "combination_not_chosen" => 1 }
      stages = { "llm-index-ideas" => { "original" => rec(0, 1, added: { "llm" => 4 },
                                                                dropped: refused) },
                 "llm-index-refine" => { "original" => rec(0, 0, extra: { "nothing_fell_short" => 1 }) },
                 "index-rank" => { "original" => rec(4, 4, added: { "combinations" => 4 }, dropped: ranked) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")

      expect(table).to include(row("Ideas from the LLM", 0, "from the LLM: 4",
                                   "named a table without its schema: 1; named a table the query doesn&#39;t use: 1; " \
                                   "couldn&#39;t be tested as written: 1; didn&#39;t parse: 1; " \
                                   "wasn&#39;t a single CREATE INDEX: 1; used something an index can&#39;t: 1; " \
                                   "used SQL QUAACK doesn&#39;t support: 1", 0, 1, "none"))
      expect(table).to include(row("The LLM's second round of ideas", 0, "none", "none", 0, 0,
                                   "skipped, since none of the LLM&#39;s ideas fell short: 1"))
      expect(table).to include(row("Trying indexes together", 4, "combinations tried: 4",
                                   "outside the top three: 1; a combination that left an index unused: 2; " \
                                   "a combination that wasn&#39;t the best: 1", 0, 4, "none"))
      stages["llm-index-refine"]["original"] = rec(0, 0, extra: { "no_ideas_tested" => 1, "fell_short" => 2 })
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include(row("The LLM's second round of ideas", 0, "none", "none", 0, 0,
                                   "skipped, since the LLM had no ideas to test: 1; " \
                                   "ideas that fell short and went back to the LLM: 2"))
    end

    it "leaves a reason with a count of zero out, and names the ones that dropped something" do
      expect(rewrite_table).to include(row("Checking each rewrite can run differently from your query", 2, "none",
                                           "planned the same as your query: 1", 0, 1, "none"))
    end

    it "shows what each rule made" do
      expect(rewrite_table).to include(row("Rewrites from QUAACK's own rules", 0, "by the rule key_in_self_join: 2",
                                           "the same as another idea: 1", 0, 1, "none"))
    end

    it "says how many rule rewrites were over the limit of ten" do
      burndown["stages"]["rewrite-rules"]["rewrites"]["dropped"]["over_cap"] = 2
      expect(rewrite_table).to include("the same as another idea: 1; over the limit of ten: 2")
    end

    it "totals the rewrites' own index searches per stage" do
      expect(rewrite_table).to include(
        row("Index ideas for the rewrites: removing duplicates and indexes you already have", 5, "none",
            "already covered by an index you have: 2", 1, 2, "none")
      )
    end

    it "says the rewrites' index searches weren't recorded when none was" do
      burndown["stages"].delete("index-dedupe")
      expect(rewrite_table).to include('<tr><th scope="row">Index ideas for the rewrites</th>' \
                                       '<td colspan="6" class="missing">not recorded</td></tr>')
    end

    it "says each LLM call in English, by what it was for" do
      calls = burndown_section[%r{<ul id="llm-calls">.*?</ul>}m]
      expect(calls.scan(%r{<li>(.*?)</li>}).flatten)
        .to eq(["Index suggestions for the original query: 2 calls",
                "Revised index suggestions for the original query: 1 call", "Rewrite suggestions: 1 call",
                "Reading your own rewrites: 1 call", "Test data written to break the rewrites: 3 calls",
                "Index suggestions for the rewrites: 4 calls",
                "Revised index suggestions for the rewrites: 2 calls"])
    end

    it "says so when the driver counted no LLM call" do
      expect(section(html, "burndown")).to include('<ul id="llm-calls"><li>No LLM calls were counted in this run' \
                                                   ".</li></ul>")
    end

    it "shows the work totals in words, and says not recorded for one the run didn't count" do
      totals = burndown_section[%r{<ul id="burndown-totals">.*?</ul>}m]
      expect(totals.scan(%r{<li>(.*?)</li>}).flatten)
        .to eq(["Plans tried with an index that wasn&#39;t built: 1,234", "Indexes really built: not recorded",
                "Measurement runs: not recorded", "Loads of made-up test data: 3"])
    end

    it "shows a total, a reason, or a source it has no words for, by its name" do
      burndown["totals"]["wild_guesses"] = 7
      burndown["stages"]["index-dedupe"]["original"]["dropped"] = { "odd_reason" => 1 }
      expect(burndown_section).to include("<li>Wild guesses: 7</li>")
      expect(index_table).to include("<td>odd reason: 1</td>")
    end

    it "escapes the names it shows" do
      burndown["stages"]["index-dedupe"]["original"]["dropped"] = { "<b>" => 1 }
      expect(burndown_section).to include("&lt;b&gt;: 1")
      expect(burndown_section).not_to include("<b>")
    end

    it "says every stage wasn't recorded when the payload has no burndown" do
      expect(section(html, "burndown").scan('class="missing">not recorded').size).to eq(17)
    end
  end

  describe "the burndown funnels" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    # A run whose rewrite stages were all counted, and whose index search
    # for the original was counted only in part.
    let(:stages) do
      { "index-from-query" => { "original" => rec(0, 4, added: { "generator_one" => 4 }) },
        "index-from-plan" => { "original" => rec(4, 6, added: { "generator_two" => 2 }) },
        "index-dedupe" => { "original" => rec(6, 3, dropped: { "duplicate" => 2, "covered_by_existing" => 1 }),
                            "rewrite_1" => rec(2, 1, dropped: { "duplicate" => 1 }) },
        "index-rank" => { "original" => rec(3, 1, dropped: { "never_used" => 2 }) },
        "rewrite-rules" => { "rewrites" => rec(0, 2, added: { "key_in_self_join" => 3 },
                                                     dropped: { "duplicate" => 1 }) },
        "llm-rewrites" => { "rewrites" => rec(2, 6, added: { "llm" => 5 }, dropped: { "inbound_check" => 1 }) },
        "operator-rewrites" => { "rewrites" => rec(6, 8, added: { "operator" => 2 }) },
        "assumption-check" => { "rewrites" => rec(8, 7, dropped: { "unmet_assumption" => 1 }) },
        "plan-pruning" => { "rewrites" => rec(7, 5, dropped: { "same_plans" => 2 }) },
        "rewrite-test" => { "rewrites" => rec(5, 4, dropped: { "s2" => 1 }) },
        "counterexamples" => { "rewrites" => rec(4, 3, dropped: { "round_1" => 1 }) },
        "rewrite-index-ideas" => { "rewrites" => rec(3, 3) },
        "measurement" => { "rewrites" => rec(3, 2, dropped: { "not_better" => 1 }) } }
    end

    let(:out) { render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })) }

    # The funnel's SVG, failing the example on the spot if there's none,
    # so a missing funnel fails on that, not on a nil further on.
    def funnel(id, html = out)
      svg = section(html, "burndown")[%r{<svg id="funnel-#{id}".*?</svg>}m]
      expect(svg).not_to be_nil, %(expected the burndown section to hold <svg id="funnel-#{id}">, but it has none)
      svg
    end

    def bands(svg) = svg.scan(%r{<g class="band[^"]*">.*?</g>}m)

    def stage(band) = band[%r{<text class="stage"[^>]*>(.*?)</text>}, 1]

    def counts(band) = band[%r{<text class="counts"[^>]*>(.*?)</text>}, 1]

    # A band's width at its top and at its bottom, from its trapezoid's
    # corners: top left, top right, bottom right, bottom left.
    def widths(band)
      left, right = band[/<polygon points="([^"]+)"/, 1].split.map { it.split(",").first.to_f }.each_slice(2).to_a
      [(left[1] - left[0]).round(2), (right[0] - right[1]).round(2)]
    end

    def width(count, largest) = (Quaack::Driver::Report::Funnel::WIDTH * count / largest).round(1)

    it "draws each funnel just above its table, as an image with a name" do
      burndown = section(out, "burndown")
      %w[index rewrite].each do |id|
        expect(funnel(id))
          .to start_with(%(<svg id="funnel-#{id}" class="funnel" role="img" aria-labelledby="funnel-#{id}-title"))
        expect(burndown.index(%(<svg id="funnel-#{id}"))).to be < burndown.index(%(<table id="burndown-#{id}">))
      end
      expect(burndown.index('<table id="burndown-index">')).to be < burndown.index('<svg id="funnel-rewrite"')
      expect(funnel("index")).to include(%(<title id="funnel-index-title">Index ideas for your query, stage by stage))
      expect(funnel("rewrite")).to include(%(<title id="funnel-rewrite-title">Rewrites, stage by stage))
    end

    it "draws one band per stage, in the table's order" do
      %w[index rewrite].each do |id|
        table = section(out, "burndown")[%r{<table id="burndown-#{id}">.*?</table>}m]
        expect(bands(funnel(id)).map { stage(it) }).to eq(table.scan(%r{<tr><th scope="row">(.*?)</th>}).flatten)
      end
      expect(bands(funnel("rewrite")).size).to eq(10)
    end

    it "sizes every band on one scale, the funnel's largest count, narrowing within a band by what it dropped" do
      rewrite = bands(funnel("rewrite")).map { widths(it) }
      expected = [[0, 2], [2, 6], [6, 8], [8, 7], [7, 5], [5, 4], [4, 3], [2, 1], [3, 3], [3, 2]]
      expect(rewrite).to eq(expected.map { |inn, out| [width(inn, 8), width(out, 8)] })
      expect(rewrite[3][0]).to eq(Quaack::Driver::Report::Funnel::WIDTH)
      expect(rewrite[4][1]).to be < rewrite[4][0]
    end

    it "labels each band with its stage, what came in and went on, and why the rest dropped out" do
      band = bands(funnel("index"))[2]
      expect(stage(band)).to eq("Removing duplicates and indexes you already have")
      expect(counts(band)).to eq("6 in, 3 out · dropped: the same as another idea: 2; " \
                                 "already covered by an index you have: 1")
      expect(band).to include("<title>Removing duplicates and indexes you already have: 6 came in. " \
                              "Added: none. Dropped: the same as another idea: 2; already covered by an index " \
                              "you have: 1. Set aside: 0. 3 went on.</title>")
    end

    it "shows a stage the run didn't count as not recorded, never as zero, outside the scale" do
      index = bands(funnel("index"))
      unknown = index.values_at(3, 4, 5)
      expect(unknown).to all(start_with('<g class="band unknown">'))
      expect(unknown.map { counts(it) }).to all(eq("not recorded"))
      expect(unknown.join).not_to match(/\b0 (in|out)\b|came in/)
      expect(unknown).to all(include('<path class="hatch" d="M'))
      expect(index.values_at(0, 1, 2, 6).join).not_to include('class="hatch"')
      expect(index.map { widths(it) }.values_at(0, 1, 2, 6))
        .to eq([[0, 4], [4, 6], [6, 3], [3, 1]].map { |inn, out| [width(inn, 6), width(out, 6)] })
      expect(index.values_at(3, 4, 5).map { widths(it) }).to all(eq([width(3, 6), width(3, 6)]))
    end

    it "draws a stage the run didn't count at a visible width after a stage that let nothing through" do
      stages["index-rank"] = { "original" => rec(2, 0, dropped: { "never_used" => 2 }) }
      stages["index-test"] = { "original" => rec(3, 0, dropped: { "never_used" => 3 }) }
      index = bands(funnel("index"))
      expect(widths(index[3])).to eq([width(3, 6), 0])
      expect(index.values_at(4, 5).map { widths(it) }).to all(eq([Quaack::Driver::Report::Funnel::UNKNOWN] * 2))
      expect(Quaack::Driver::Report::Funnel::UNKNOWN).to be >= Quaack::Driver::Report::Funnel::WIDTH / 4
    end

    it "draws a stage the run didn't count no narrower than its minimum after a tiny count" do
      stages["index-from-plan"] = { "original" => rec(4, 1000, added: { "generator_two" => 996 }) }
      stages["index-test"] = { "original" => rec(3, 3, dropped: {}) }
      index = bands(funnel("index"))
      expect(widths(index[3])).to eq([width(3, 1000), width(3, 1000)])
      expect(index.values_at(4, 5).map { widths(it) }).to all(eq([Quaack::Driver::Report::Funnel::UNKNOWN] * 2))
    end

    it "shows a stage that counted zero as zero, apart from one that wasn't counted" do
      stages["index-test"] = { "original" => rec(0, 0) }
      band = bands(funnel("index"))[3]
      expect(band).to start_with('<g class="band">')
      expect(counts(band)).to eq("0 in, 0 out")
      expect(widths(band)).to eq([0, 0])
    end

    it "draws every band as unknown when the payload has no burndown" do
      index = bands(funnel("index", html))
      expect(index.size).to eq(7)
      expect(index).to all(start_with('<g class="band unknown">'))
      expect(index.map { widths(it) }).to all(eq([Quaack::Driver::Report::Funnel::WIDTH] * 2))
      expect(funnel("rewrite", html)).not_to match(/\d+ (in|out)\b/)
    end

    it "cuts a long label short beside its band, and keeps the whole of it in the tooltip" do
      stages["index-dedupe"]["original"]["dropped"] = (1..12).to_h { ["reason_number_#{it}", it] }
      band = bands(funnel("index"))[2]
      whole = "6 in, 3 out · dropped: #{band[/Dropped: (.*?)\. Set aside/, 1]}"
      expect(whole).to include("reason number 1: 1; ").and include("reason number 12: 12")
      expect(whole.length).to be > Quaack::Driver::Report::Funnel::LINE
      expect(counts(band)).to eq("#{whole[0, Quaack::Driver::Report::Funnel::LINE - 1]}…")
    end

    it "leaves a label that just fits whole" do
      prefix = "6 in, 3 out · dropped: "
      name = "x" * (Quaack::Driver::Report::Funnel::LINE - prefix.length - ": 1".length)
      stages["index-dedupe"]["original"]["dropped"] = { name => 1 }
      expect(counts(bands(funnel("index"))[2])).to eq("#{prefix}#{name}: 1")
      expect(counts(bands(funnel("index"))[2]).length).to eq(Quaack::Driver::Report::Funnel::LINE)
    end

    it "says what a stage set aside, beside its band and in its tooltip" do
      stages["index-dedupe"]["original"] = rec(6, 3, dropped: { "duplicate" => 2 }, set_aside: 1200)
      band = bands(funnel("index"))[2]
      expect(counts(band)).to eq("6 in, 3 out, 1,200 set aside · dropped: the same as another idea: 2")
      expect(band).to include(" Set aside: 1,200. 3 went on.</title>")
    end

    it "takes the scale's largest count from what went on, too" do
      stages["operator-rewrites"] = { "rewrites" => rec(6, 9, added: { "operator" => 3 }) }
      rewrite = bands(funnel("rewrite")).map { widths(it) }
      expected = [[0, 2], [2, 6], [6, 9], [8, 7], [7, 5], [5, 4], [4, 3], [2, 1], [3, 3], [3, 2]]
      expect(rewrite).to eq(expected.map { |inn, out| [width(inn, 9), width(out, 9)] })
      expect(rewrite[2][1]).to eq(Quaack::Driver::Report::Funnel::WIDTH)
    end

    it "draws a funnel whose every count is zero as zero wide, and its unknown stages at their minimum" do
      stages.transform_values! { |records| records.transform_values { rec(0, 0) } }
      index = bands(funnel("index"))
      expect(index.values_at(0, 1, 2, 6).map { widths(it) }).to all(eq([0, 0]))
      expect(index.values_at(3, 4, 5).map { widths(it) }).to all(eq([Quaack::Driver::Report::Funnel::UNKNOWN] * 2))
      expect(bands(funnel("rewrite")).map { widths(it) }).to all(eq([0, 0]))
    end

    # The solid line along a partly counted band's top, as its x's and y's.
    def known_top(band)
      line = band.match(/<line class="known" x1="([^"]+)" y1="([^"]+)" x2="([^"]+)" y2="([^"]+)"/)
      expect(line).not_to be_nil, "expected a solid line along the band's top, but it has none"
      line.captures.map(&:to_f)
    end

    it "draws what's known of a stage that counted what came in but not what went on" do
      stages["index-test"] = { "original" => rec(3, 1, dropped: { "never_used" => 1 }).except("out") }
      index = bands(funnel("index"))
      band = index[3]
      top = rows_y(band).first
      expect(band).to start_with('<g class="band partial">')
      expect(known_top(band)).to eq([80.0, top, 240.0, top])
      expect(widths(band)).to eq([width(3, 6), width(3, 6)])
      expect(band).to include('<path class="hatch" d="M')
      expect(counts(band)).to eq("3 in, out not recorded · dropped: never used by the planner: 1")
      expect(band).to include("<title>Asking the planner whether it would use each one: 3 came in. Added: none. " \
                              "Dropped: never used by the planner: 1. Set aside: 0. How many went on: not recorded. " \
                              "This run didn&#39;t count it, which doesn&#39;t mean none.</title>")
      expect(band).not_to match(/\b\d+ (out|went on)\b/)
      expect(index.values_at(4, 5).map { widths(it) }).to all(eq([width(3, 6), width(3, 6)]))
    end

    it "counts what came in to a partly counted stage in the funnel's scale" do
      stages["index-test"] = { "original" => rec(12, 0).except("out") }
      expect(known_top(bands(funnel("index"))[3]).values_at(0, 2)).to eq([0.0, Quaack::Driver::Report::Funnel::WIDTH])
      expect(widths(bands(funnel("index"))[2])).to eq([width(6, 12), width(3, 12)])
    end

    it "draws a partly counted stage's unknown part no narrower than its minimum" do
      stages["index-test"] = { "original" => rec(1, 0).except("out") }
      band = bands(funnel("index"))[3]
      known = known_top(band)
      expect((known[2] - known[0]).round(1)).to eq(width(1, 6))
      expect(widths(band)).to eq([Quaack::Driver::Report::Funnel::UNKNOWN] * 2)
      expect(bands(funnel("index")).values_at(4, 5).map { widths(it) })
        .to all(eq([Quaack::Driver::Report::Funnel::UNKNOWN] * 2))
    end

    it "still shows a stage that counted what went on but not what came in as not recorded" do
      stages["index-test"] = { "original" => rec(1, 3).except("in") }
      band = bands(funnel("index"))[3]
      expect(band).to start_with('<g class="band unknown">')
      expect(counts(band)).to eq("not recorded")
    end

    it "shows a stage with a negative count as not recorded, never as that count" do
      stages["index-test"] = { "original" => rec(-1, 3) }
      stages["llm-index-ideas"] = { "original" => rec(3, -2) }
      index = bands(funnel("index"))
      expect(index.values_at(3, 4)).to all(start_with('<g class="band unknown">'))
      expect(index.values_at(3, 4).map { counts(it) }).to all(eq("not recorded"))
      expect(index.values_at(3, 4).join).not_to match(/-[12]\b/)
    end

    # A band's trapezoid's y at its corners: top left, top right, bottom right, bottom left.
    def rows_y(band) = band[/<polygon points="([^"]+)"/, 1].split.map { it.split(",").last.to_f }

    it "stacks its bands top to bottom, a gap apart, in a picture just tall enough for them" do
      funnel_module = Quaack::Driver::Report::Funnel
      %w[index rewrite].each do |id|
        svg = funnel(id)
        ys = bands(svg).map { rows_y(it) }
        ys.each do |top, top2, bottom, bottom2|
          expect([top2, bottom2, bottom - top]).to eq([top, bottom, funnel_module::HEIGHT])
        end
        expect(ys.first.first).to eq(funnel_module::TOP)
        expect(ys.each_cons(2).map { |above, below| below.first - above.last }).to all(eq(funnel_module::GAP))
        height = (ys.last.last + funnel_module::GAP).to_i
        expect(svg[/viewBox="([^"]+)"/, 1]).to eq("0 0 #{funnel_module::VIEW_WIDTH} #{height}")
      end
      expect(funnel("index")[/viewBox="([^"]+)"/, 1]).to eq("0 0 940 354")
    end

    it "sets each band's words to its right, the stage's name over its counts, within the band's height" do
      funnel_module = Quaack::Driver::Report::Funnel
      expect(funnel_module::LABEL_X).to be > funnel_module::WIDTH
      bands(funnel("index")).each do |band|
        top = rows_y(band).first
        texts = band.scan(/<text class="(\w+)" x="([^"]+)" y="([^"]+)">/)
        expect(texts).to eq([["stage", funnel_module::LABEL_X.to_s, (top + 18).to_i.to_s],
                             ["counts", funnel_module::LABEL_X.to_s, (top + 37).to_i.to_s]])
      end
    end

    it "stripes an unknown band across its whole face at 45 degrees, every stripe cut to its edges" do
      funnel_module = Quaack::Driver::Report::Funnel
      [[funnel("index"), 3], [funnel("index", html), 0], [funnel("index", html), 6]].each do |svg, i|
        band = bands(svg)[i]
        top = rows_y(band).first
        bottom = top + funnel_module::HEIGHT
        left, right = band[/<polygon points="([^"]+)"/, 1].split.map { it.split(",").first.to_f }.first(2)
        stripes = band[/<path class="hatch" d="([^"]+)"/, 1].scan(/M([\d.]+),([\d.]+)L([\d.]+),([\d.]+)/)
                                                            .map { it.map(&:to_f) }
        stripes.each do |x1, y1, x2, y2|
          expect([x1, x2]).to all(be_between(left, right))
          expect([y1, y2]).to all(be_between(top, bottom))
          expect((x1 - x2).round(1)).to eq((y2 - y1).round(1))
          expect(y1 == top || x1 == right).to be(true)
          expect(y2 == bottom || x2 == left).to be(true)
        end
        crossings = stripes.map { |x1, y1, _, _| (x1 + y1 - top).round(1) }
        expect(crossings.first).to eq((left + funnel_module::STRIPE).round(1))
        expect(crossings.each_cons(2).map { |a, b| (b - a).round(1) }).to all(eq(funnel_module::STRIPE))
        expect(crossings.last).to be > right + funnel_module::HEIGHT - funnel_module::STRIPE
      end
    end

    it "says in an unknown band's tooltip that the run didn't count it, not that it counted none" do
      band = bands(funnel("index"))[3]
      expect(band).to include("<title>#{stage(band)}: not recorded. " \
                              "This run didn&#39;t count it, which doesn&#39;t mean none.</title>")
    end

    it "escapes what it shows, and sets no SQL apart in it" do
      evil = "<script>alert(1)</script>]]>"
      stages["rewrite-rules"]["rewrites"]["added"] = { evil => 3 }
      stages["measurement"]["rewrites"]["dropped"] = { evil => 1 }
      svg = funnel("rewrite")
      expect(svg).not_to include("<script")
      expect(svg).not_to include("]]>")
      expect(svg).to include("by the rule &lt;script&gt;alert(1)&lt;/script&gt;]]&gt;: 3")
      expect(svg).to include("dropped: &lt;script&gt;alert(1)&lt;/script&gt;]]&gt;: 1")
      expect(svg).not_to include("<code")
    end

    it "escapes its words without setting marked SQL apart, since an SVG text can't hold code" do
      expect(Quaack::Driver::Report::Funnel.text("on #{Quaack::Driver::Report::Format.sql_span("a < 1")}"))
        .to eq("on a &lt; 1")
    end

    it "keeps each table, with its exact numbers, under its funnel" do
      table = section(out, "burndown")[%r{<table id="burndown-rewrite">.*?</table>}m]
      expect(table).to include(%(<tr><th scope="row">Your own rewrites</th><td class="num">6</td>))
    end
  end

  describe "escaping" do
    # A sentinel with the characters that would break out of text and out
    # of an attribute. It goes in every field of the payload that can hold
    # a String, and in the counts too, since a cell prints whatever it's
    # given.
    let(:z) { %(<zz&"zz>) }
    let(:escaped) { "&lt;zz&amp;&quot;zz&gt;" }

    let(:counts) { { "total_blocks" => z, "hit" => z, "read" => z, "stable" => false, "timed_out" => false } }
    let(:node) do
      { "node" => z, "relation" => z, "index" => z, "est_rows" => z, "actual_rows" => z, "selectivity" => nil }
    end
    let(:record) do
      { "in" => z, "added" => { z => 1 }, "dropped" => { z => 1 }, "set_aside" => z, "out" => z,
        "extra" => { z => 1 } }
    end

    let(:sentinels) do
      { "type" => "report",
        "top" => [{ "label" => "#{z}:top:1", "slow_blocks" => z, "total_blocks_sum" => z, "footprint" => 8192 }],
        "excluded" => { "#{z}:none" => "not_better", "#{z}:top:2" => z }, "infinite_sets" => [z],
        "original_sql" => "SELECT #{z}", "original_measurements" => { z => counts, "slow" => { "timed_out" => true } },
        "labels" => [{ "label" => "#{z}:top:1", "search" => z, "indexes" => ["quaack_z", z], "timed_out" => false,
                       "measurements" => { z => counts }, "verdicts" => { z => z } },
                     { "label" => "#{z}:top:3", "search" => z, "indexes" => [z], "timed_out" => true,
                       "measurements" => nil, "verdicts" => nil }],
        "rewrites" => [{ "rewrite" => z, "sql" => "SELECT #{z}", "source" => "rule", "rules" => [z, z],
                         "fate" => "rewrite_test_disproved", "scenario" => z, "rule" => z, "round" => z, "after" => z,
                         "plan" => [node], "untested_atoms" => [z, "a < $1"], "covered" => [z],
                         "evidence" => false }],
        "indexes" => { "quaack_z" => { "ddl" => "CREATE INDEX ON #{z}", "size" => 8192,
                                       "covered_by" => { "name" => z, "size_bytes" => 1 },
                                       "makes_redundant" => [{ "name" => z, "size_bytes" => nil }] },
                       z => { "ddl" => nil, "size" => z, "covered_by" => nil, "makes_redundant" => [] } },
        "original_plan" => [node], "timed_out_count" => 1,
        "rule_bugs" => [{ "rewrite" => z, "rules" => [z], "step" => z }],
        "burndown" => { "stages" => { "index-dedupe" => { "original" => record, z => record },
                                      "rewrite-rules" => { "rewrites" => record } },
                        "totals" => { z => 1 } } }
    end

    let(:negative_sentinels) do
      sentinels.merge(
        "top" => [],
        "negative" => { "declined" => [{ "ddl" => z, "reason" => "hypopg_refused", "sqlstate" => z,
                                         "searches" => [z, "rewrite_#{z}"] },
                                       { "ddl" => nil, "reason" => z, "sqlstate" => z, "searches" => [z] }],
                        "existing" => [{ "ddl" => z, "covered_by" => { "name" => z, "size_bytes" => z },
                                         "searches" => [z] }] }
      )
    end

    def rendered(payload) = described_class.render(payload, run_id: z, llm_calls: { z => 1 })

    # Each place a value is printed, by the markup just before it.
    def expect_escaped(out, *places)
      places.each { expect(out).to include("#{it}#{escaped}") }
    end

    it "lets no markup from a winning payload through, in text or in an attribute" do
      out = rendered(sentinels)
      expect(out).not_to include("<zz")
      expect(out).not_to include('"zz')
      expect(out.scan(escaped).size).to be > 60
    end

    it "lets no markup from a negative payload through, in text or in an attribute" do
      out = rendered(negative_sentinels)
      expect(out).not_to include("<zz")
      expect(out).not_to include('"zz')
      expect(out.scan(escaped).size).to be > 40
    end

    it "prints, escaped, every value a winning report shows" do
      expect_escaped(rendered(sentinels),
                     "<title>QUAACK report ", "<h1>QUAACK report ", "<li>", '<article class="rewrite" id="',
                     %(<article class="rewrite" id="#{escaped}"><details class="query">\n<summary><h3>),
                     "QUAACK found something better than your query as it is: ",
                     "<code>SELECT ", "rewrite rules ", '<li><code class="sql">',
                     '<tr class="rank"><td class="num">1</td><td>',
                     '</td><td class="num">', '<a href="#', %(<a href="##{escaped}">), "<h3>1. ", "<tr><td>",
                     "</td><td>",
                     %(<section id="explanation"><h2>Why the winner reads fewer blocks</h2>\n<p>), "<p>How it runs ",
                     "<ul><li>", '<td class="step">', %(<td><code class="sql">), "<td>",
                     "<td>by the rule ", %(<td><code class="sql">), 'couldn&#39;t describe (<code class="sql">')
    end

    it "prints, escaped, every value a negative report shows" do
      expect_escaped(rendered(negative_sentinels),
                     '<ul id="negative-rewrites"><li>', %(<tr><td><code class="sql">), "</code></td><td>", ", rewrite_",
                     "(Postgres error code ", %(#{escaped}</td><td>), "<tbody>\n<tr><td>",
                     "</td><td>Made by QUAACK&#39;s own rewrite rules ", %(<td><code class="sql">))
    end

    it "escapes what the payload carries in the first report too" do
      payload["original_sql"] = "SELECT <b>orig</b>"
      payload["rewrites"].first.merge!("sql" => "SELECT <b>rw</b>", "untested_atoms" => ["<b>atom</b>"],
                                       "covered" => ["<b>atom</b>"])
      payload["indexes"]["quaack_a"].merge!("ddl" => "CREATE INDEX ON <b>t</b>",
                                            "covered_by" => { "name" => "<b>idx</b>", "size_bytes" => 1 })
      payload["original_plan"].first["relation"] = "<b>rel</b>"
      payload["excluded"] = { "<b>label</b>" => "<b>why</b>" }
      out = described_class.render(payload, run_id: "<b>RUN</b>", llm_calls: { "<b>step</b>" => 1 })
      expect(out).not_to include("<b>")
      expect(out).to include("&lt;b&gt;RUN&lt;/b&gt;").and include("&lt;b&gt;orig&lt;/b&gt;")
      expect(out).to include("&lt;b&gt;idx&lt;/b&gt;").and include("&lt;b&gt;rel&lt;/b&gt;")
    end

    it "keeps escaping inside the code that sets SQL apart" do
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.t USING btree (a) WHERE b < '<b>'"
      expect(section(render(payload), "ranking"))
        .to include("Your query with a new index on #{sq("public.t (a) WHERE b &lt; &#39;&lt;b&gt;&#39;")}")
    end

    # The value with no \u0001 or \u0002 in any String it holds.
    def scrub(value)
      case value
      when String then value.delete("\u0001\u0002")
      when Hash then value.to_h { |k, v| [scrub(k), scrub(v)] }
      when Array then value.map { scrub(it) }
      else value
      end
    end

    it "lets no control character in a value open, close, or mark SQL the report didn't" do
      payload["rewrites"].first["rules"] = ["\u0001x\u0002"]
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.t USING btree (a\u0002) WHERE \u0001b"
      payload["original_plan"].first["relation"] = "\u0002\u0001"
      payload["excluded"] = { "\u0001rewrite_1:top:1\u0002" => "not_better" }
      run_id = "R\u0001x\u0002"
      out = described_class.render(payload, run_id:, llm_calls: { "\u0001s\u0002" => 1 })
      expect(out).to eq(described_class.render(scrub(payload), run_id:, llm_calls: { "s" => 1 }))
      expect(out).not_to match(/[\u0001\u0002]/)
      expect(out).to include("<title>QUAACK report Rx</title>").and include("<h1>QUAACK report Rx</h1>")
      expect(section(out, "queries")).to include("rewrite rule x.").and(satisfy { !it.include?('class="sql">x') })
      expect(section(out, "ranking")).to include("a new index on #{sq("public.t (a) WHERE b")}")
      expect(section(out, "explanation"))
        .to include(%(Seq Scan <strong class="mark">differs</strong></td><td>#{sq("")}</td>))
      expect(out.scan("<code").size).to eq(out.scan("</code>").size)
    end
  end

  it "writes the report to a file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.html")
      expect(described_class.write(payload, run_id: "RUN-1", path:)).to eq(path)
      expect(File.read(path)).to eq(html)
    end
  end
end
