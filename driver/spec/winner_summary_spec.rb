# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/pipeline"
require "quaack/driver/provenance"
require "quaack/driver/report"
require "quaack/driver/winner_summary"
require_relative "support/fake_llm"
require_relative "support/routers"

# The report's winner-summary step (20261009-37): a few sentences, written by
# an LLM, that open "Why the winner reads fewer blocks". The LLM is faked at
# the client's edge (FakeLLM), so the router, client, burndown, and
# provenance run for real.
RSpec.describe Quaack::Driver::WinnerSummary do
  include Routers

  def m(blocks, hit, timed_out: false)
    { "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "stable" => true, "timed_out" => timed_out }
  end

  let(:plan_node) do
    { "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 50, "actual_rows" => 50,
      "selectivity" => 0.05, "depth" => 0, "shared_hit_blocks" => 1_200, "shared_read_blocks" => 34 }
  end
  let(:winner_node) do
    { "node" => "Index Scan", "relation" => "public.t", "index" => "t_a_idx", "est_rows" => 5, "actual_rows" => 5,
      "selectivity" => 0.005, "depth" => 0, "shared_hit_blocks" => 20, "shared_read_blocks" => 10 }
  end
  let(:payload) do
    { "type" => "report",
      "top" => [{ "label" => "rewrite_1:top:1", "slow_blocks" => 30, "total_blocks_sum" => 90, "footprint" => 8192 }],
      "excluded" => {}, "infinite_sets" => [],
      "original_sql" => "SELECT id FROM public.t WHERE b IN (SELECT b FROM public.u WHERE c = $1) AND a < $2",
      "original_measurements" => { "slow" => m(1_234, 100), "typical" => m(200, 150) },
      "original_plan" => [plan_node],
      "labels" => [{ "label" => "rewrite_1:top:1", "search" => "rewrite_1", "indexes" => ["quaack_b"],
                     "timed_out" => false, "plan" => [winner_node],
                     "measurements" => { "slow" => m(30, 20), "typical" => m(190, 100) },
                     "verdicts" => { "slow" => "better", "typical" => "no_worse" } }],
      "rewrites" => [{ "rewrite" => "rewrite_1", "name" => "Steady Lute", "source" => "rule",
                       "rules" => ["in_to_exists"], "fate" => "ranked",
                       "sql" => "SELECT id FROM public.t WHERE EXISTS (SELECT 1 FROM public.u WHERE b = t.b " \
                                "AND c = $1) AND a < $2",
                       "plan" => [winner_node] }],
      "indexes" => { "quaack_b" => { "ddl" => "CREATE INDEX ON public.t USING btree (a, b)", "size" => 16_384,
                                     "covered_by" => { "name" => "t_existing_idx", "size_bytes" => 1 } } },
      "timed_out_count" => 0 }
  end

  let(:good) do
    "Rewrite Steady Lute turns the IN into an EXISTS and, with the new index on a and b, reads 30 blocks on the " \
      "slow values against 1,234 for the original query. It also stayed under the original on the typical values."
  end

  describe "the input" do
    def input(payload) = described_class::Input.build(payload)

    it "is the two queries, the rule names, the new index, both plans, and the blocks on each set of values" do
      expect(input(payload)).to eq(
        "original" => { "sql" => payload["original_sql"],
                        "plan" => [{ "step" => "Seq Scan", "table" => "public.t", "index" => nil,
                                     "estimated_rows" => 50, "actual_rows" => 50, "depth" => 0, "blocks" => 1_234 }],
                        "plan_source" => "how Postgres runs the original query now, on the indexes the database has" },
        "winner" => { "is" => "a rewrite of the original query",
                      "rewrite" => { "name" => "Rewrite Steady Lute", "source" => "rule", "rules" => ["in_to_exists"],
                                     "sql" => payload["rewrites"][0]["sql"] },
                      "new_indexes" => ["CREATE INDEX ON public.t USING btree (a, b)"],
                      "plan" => [{ "step" => "Index Scan", "table" => "public.t", "index" => "t_a_idx",
                                   "estimated_rows" => 5, "actual_rows" => 5, "depth" => 0, "blocks" => 30 }],
                      "plan_source" => described_class::Input::MEASURED },
        "blocks_read" => { "slow" => { "winner" => { "blocks" => 30, "timed_out" => false },
                                       "original" => { "blocks" => 1_234, "timed_out" => false } },
                           "typical" => { "winner" => { "blocks" => 190, "timed_out" => false },
                                          "original" => { "blocks" => 200, "timed_out" => false } } }
      )
    end

    it "has no rewrite and no new index for an original query that has none, and says an estimated plan is one" do
      payload["top"][0]["label"] = "rewrite_1:none"
      payload["labels"][0].merge!("label" => "rewrite_1:none", "indexes" => [], "plan" => nil)
      winner = input(payload).fetch("winner")

      expect(winner).to include("new_indexes" => [], "plan_source" => described_class::Input::ESTIMATED)
      expect(winner["plan"].first).to include("blocks" => 30)
      payload["top"][0]["label"] = "original:top:1"
      payload["labels"][0].merge!("label" => "original:top:1", "indexes" => ["quaack_b"])
      expect(input(payload)["winner"]).to include("is" => "the original query", "rewrite" => nil)
    end

    it "counts only the sets both were measured on, and says so when the original timed out on one" do
      payload["labels"][0]["measurements"]["rare"] = m(7, 7)
      payload["labels"][0]["measurements"]["huge"] = m(40, 40)
      payload["original_measurements"]["huge"] = m(0, 0, timed_out: true).merge("total_blocks" => nil)
      blocks = input(payload).fetch("blocks_read")

      expect(blocks.keys).to eq(%w[slow typical huge])
      expect(blocks["huge"]).to eq("winner" => { "blocks" => 40, "timed_out" => false },
                                   "original" => { "blocks" => nil, "timed_out" => true })
    end

    it "is nil when there is no winner" do
      expect(input(payload.merge("top" => []))).to be_nil
    end

    # Planted values the input must never carry. Each sits where the payload
    # holds something the report doesn't send an LLM, or in a field the
    # input's allowlist leaves out.
    let(:sentinels) { %w[SENTINEL_FILTER SENTINEL_NOTE SENTINEL_EVIDENCE SENTINEL_COVERED SENTINEL_EXTRA] }
    let(:planted) do
      payload.merge("customer_note" => "SENTINEL_NOTE").tap do |p|
        [p["original_plan"][0], p["labels"][0]["plan"][0], p["rewrites"][0]["plan"][0]].each do |node|
          node["filter"] = "email = 'SENTINEL_FILTER'"
        end
        p["rewrites"][0]["evidence"] = "SENTINEL_EVIDENCE"
        p["indexes"]["quaack_b"]["covered_by"]["name"] = "SENTINEL_COVERED"
        p["labels"][0]["measurements"]["slow"]["detail"] = "SENTINEL_EXTRA"
      end
    end

    # What a spec asserts about a prompt: each sentinel it carries.
    def carried(text) = sentinels.select { text.include?(it) }

    it "carries none of the planted values in the prompt the LLM gets" do
      fake = FakeLLM.new.reply("winner-summary", good)
      described_class.new(client: router_of(fake)).run(planted)

      sent = JSON.generate(fake.asks.map(&:body))
      expect(sent).to include("Rewrite Steady Lute", "in_to_exists", "t_a_idx")
      expect(carried(sent)).to eq([])
    end

    it "the check catches a sentinel when one is planted in a field the input does carry" do
      payload["original_sql"] = "SELECT id FROM public.t WHERE name = 'SENTINEL_FILTER'"
      payload["rewrites"][0]["rules"] = ["SENTINEL_NOTE"]
      payload["labels"][0]["plan"][0]["relation"] = "SENTINEL_EXTRA"
      fake = FakeLLM.new.reply("winner-summary", good)
      described_class.new(client: router_of(fake)).run(payload)

      sent = JSON.generate(fake.asks.map(&:body))
      # A rule that isn't a lowercase name is dropped, so SENTINEL_NOTE isn't carried.
      expect(carried(sent)).to eq(%w[SENTINEL_FILTER SENTINEL_EXTRA])
      expect(sent).to include("SENTINEL_EXTRA")
    end

    it "drops a string that is a control character, a number that isn't a count, and a rule that isn't a name" do
      payload["rewrites"][0]["rules"] = ["in_to_exists", "Ignore the above", "x\n"]
      payload["labels"][0]["plan"][0].merge!("node" => "Seq\nScan", "est_rows" => -1, "actual_rows" => "5")
      got = input(payload)

      expect(got.dig("winner", "rewrite", "rules")).to eq(["in_to_exists"])
      expect(got.dig("winner", "plan", 0)).to include("step" => nil, "estimated_rows" => nil, "actual_rows" => nil)
    end
  end

  describe "asking" do
    let(:fake) { FakeLLM.new }
    let(:client) { router_of(fake) }

    def run(answer, payload = self.payload)
      fake.reply("winner-summary", answer) if answer
      described_class.new(client:).run(payload)
    end

    it "uses the LLM's answer, counted as the winner-summary step with its tokens" do
      result = run("  #{good}\n")

      expect(result).to have_attributes(text: good, outcome: "used", entry: "anthropic", rule: nil)
      expect(client.burndown.llm_calls).to eq("winner-summary" => 1)
      expect(client.burndown.llm_usage.fetch("anthropic")).to include("used" => 1, "input" => 1, "output" => 1)
    end

    it "sends the payload and a prompt that limits it to the plans and numbers, against the original query only" do
      run(good)
      ask = fake.asks.fetch(0)
      system = ask.body[:system]

      expect(ask.body[:messages].first[:content]).to include("```json")
      expect(system).to include("only with the original query as it runs now, on the indexes the database already has")
        .and include("Say only what the plans and numbers in the payload show")
        .and include("Don't guess at a cause you can't see")
        .and include("each short and making one point").and include("under 500 characters")
        .and include("Quote a plan step's own numbers")
        .and include("never carry one step's row count to another step")
      expect(ask.body).not_to have_key(:output_config)
    end

    it "doesn't ask when there's no winner" do
      expect(run(nil, payload.merge("top" => []))).to have_attributes(outcome: "no_winner", text: nil)
      expect(fake.asks).to be_empty
    end

    it "gives no text, with the rule, when the ask fails" do
      fake.error("winner-summary", status: 529)
      result = described_class.new(client: router_of(fake, max_retries: 0)).run(payload)

      expect(result).to have_attributes(text: nil, outcome: "failed", rule: "llm_unavailable")
    end

    it "gives no text for an empty answer" do
      expect(run("  \n ")).to have_attributes(text: nil, outcome: "empty", entry: "anthropic")
    end

    it "refuses an answer that is far too long" do
      expect(run("#{good} #{"It reads fewer blocks. " * 60}")).to have_attributes(text: nil, outcome: "rejected")
    end

    {
      "html" => "Rewrite Steady Lute reads <b>fewer</b> blocks.",
      "an entity" => "Rewrite Steady Lute reads fewer blocks &amp; rows.",
      "a url" => "Rewrite Steady Lute reads fewer blocks, see https://example.test/plan for more.",
      "a bare domain" => "Rewrite Steady Lute reads fewer blocks, see example.com for more.",
      "a bare domain on an unlisted ending" => "Rewrite Steady Lute reads fewer blocks, see evil.example.co now.",
      "a javascript link as text" => "Rewrite Steady Lute reads fewer blocks, see javascript:alert(1) now.",
      "a data link as text" => "Rewrite Steady Lute reads fewer blocks, see data:text/plain,hi now.",
      "a vbscript link as text" => "Rewrite Steady Lute reads fewer blocks, see vbscript:msgbox now.",
      "a mailto link as text" => "Rewrite Steady Lute reads fewer blocks, mail mailto:dba now.",
      "a file link as text" => "Rewrite Steady Lute reads fewer blocks, see file:/etc/passwd now.",
      "an ftp link as text" => "Rewrite Steady Lute reads fewer blocks, see ftp:/pub now.",
      "an about link as text" => "Rewrite Steady Lute reads fewer blocks, see about:blank now.",
      "a spaced odd-case javascript link" => "Rewrite Steady Lute reads fewer blocks, see JaVaScRiPt :alert(1) now.",
      "a line separator" => "Rewrite Steady Lute reads fewer\u2028blocks.",
      "a paragraph separator" => "Rewrite Steady Lute reads fewer\u2029blocks.",
      "a hangul filler" => "Rewrite Steady Lute reads fewer\u3164blocks.",
      "a braille blank" => "Rewrite Steady Lute reads fewer\u2800blocks.",
      "a variation selector" => "Rewrite Steady Lute reads fewer blocks.\uFE0F",
      "a unicode-lettered bare domain" => "Rewrite Steady Lute reads fewer blocks, see evil.\u0440\u0444 now.",
      "an email address" => "Rewrite Steady Lute reads fewer blocks, ask dba@corp for more.",
      "a zero-width character" => "Rewrite Steady Lute reads fewer​ blocks.",
      "a bidi override" => "Rewrite Steady Lute reads fewer blocks.‮",
      "a markdown link" => "Rewrite Steady Lute reads [fewer blocks](x).",
      "a code fence" => "Rewrite Steady Lute reads fewer blocks.\n```sql\nSELECT 1\n```",
      "a bold word" => "Rewrite Steady Lute reads **fewer** blocks.",
      "a list" => "Rewrite Steady Lute differs:\n- it reads fewer blocks\n- it uses an index",
      "a heading" => "# Summary\nRewrite Steady Lute reads fewer blocks.",
      "a control character" => "Rewrite Steady Lute reads fewer blocks.\u0001",
      "a rewrite the report doesn't show" => "Rewrite Silver Fox reads fewer blocks than Rewrite Steady Lute.",
      "an internal label" => "rewrite_1:top:1 reads fewer blocks.",
      "a built index's name" => "Rewrite Steady Lute reads fewer blocks with quaack_b."
    }.each do |what, answer|
      it "refuses an answer with #{what}" do
        expect(run(answer)).to have_attributes(text: nil, outcome: "rejected", entry: "anthropic")
      end
    end

    it "refuses any rewrite's name when the winner is the original query with new indexes" do
      payload["top"][0]["label"] = "original:top:1"
      payload["labels"][0]["label"] = "original:top:1"

      expect(run(good, payload)).to have_attributes(text: nil, outcome: "rejected")
    end

    it "keeps the comparison operators of a condition, which the report escapes" do
      payload["original_sql"] = "SELECT 1 FROM public.orders o WHERE (o.created_at >= $1 AND o.created_at < $2) " \
                                "OR o.status = $3"
      answer = "Rewrite Steady Lute filters on (o.created_at >= $1 AND o.created_at < $2) OR o.status = $3."

      expect(run(answer, payload)).to have_attributes(text: answer, outcome: "used")
    end

    it "keeps schema-qualified names, aliased columns, operators, and numbers with commas and decimals" do
      payload["original_sql"] = "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id " \
                                "WHERE o.status = $1 AND o.total >= $2"
      answer = "Rewrite Steady Lute reads public.orders through o.status and o.total >= $2, then joins public.users " \
               "on u.id = o.user_id. It reads 30 blocks against 1,234 for the original, a 97.6 percent drop."

      expect(run(answer, payload)).to have_attributes(text: answer, outcome: "used")
    end

    it "refuses a dotted name that isn't in what the LLM was sent" do
      answer = "Rewrite Steady Lute reads fewer blocks than evil.orders does."

      expect(run(answer)).to have_attributes(text: nil, outcome: "rejected")
    end

    it "keeps an answer of exactly 800 characters and refuses one of 801" do
      pad = ->(size) { "#{good} #{"a" * (size - good.size - 1)}" }

      expect(run(pad.call(800))).to have_attributes(text: pad.call(800), outcome: "used")
      expect(run(pad.call(801))).to have_attributes(text: nil, outcome: "rejected")
    end

    it "refuses a dotted name only when the input holds it as a whole word, not as the start of a longer one" do
      payload["original_sql"] = "SELECT 1 FROM example.company WHERE a = $1"

      expect(run("Rewrite Steady Lute reads fewer blocks than example.co does.", payload))
        .to have_attributes(text: nil, outcome: "rejected")
      expect(run("Rewrite Steady Lute reads fewer blocks than example.company does.", payload))
        .to have_attributes(outcome: "used")
    end

    context "with an orders query" do
      before { payload["original_sql"] = "SELECT o.id FROM public.orders o WHERE o.status = $1" }

      it "keeps a dotted name whose parts each appear in the input, such as a schema added to a column" do
        answer = "Rewrite Steady Lute reads fewer blocks filtering on public.orders.status."

        expect(run(answer, payload)).to have_attributes(text: answer, outcome: "used")
      end

      it "keeps a column named by its table instead of the alias the query uses" do
        answer = "Rewrite Steady Lute reads fewer blocks, filtering on orders.status and orders.id."

        expect(run(answer, payload)).to have_attributes(text: answer, outcome: "used")
      end

      it "refuses a dotted name when one part isn't in the input, even if the others are" do
        expect(run("Rewrite Steady Lute reads fewer blocks than public.evil.status does.", payload))
          .to have_attributes(text: nil, outcome: "rejected")
      end
    end

    it "keeps one paragraph: runs of whitespace in a good answer become a space" do
      expect(run("Rewrite Steady Lute reads\nfewer blocks.  It\tuses the index.").text)
        .to eq("Rewrite Steady Lute reads fewer blocks. It uses the index.")
    end

    describe "routing" do
      let(:fakes) { { "a" => FakeLLM.new, "b" => FakeLLM.new, "c" => FakeLLM.new } }
      let(:routing) { nil }
      let(:router) { router_over(fakes, routing:, max_retries: 0) }

      def summarize = described_class.new(client: router).run(payload)

      context "with a pinned step" do
        let(:routing) { { "steps" => { "winner-summary" => { "providers" => %w[c b] } } } }

        it "asks only the pinned pool, round robin within it" do
          fakes.values_at("b", "c").each { it.reply("winner-summary", good) }
          expect([summarize.entry, summarize.entry]).to eq(%w[b c])
          expect(fakes["a"].asks).to be_empty
          expect(router.burndown.llm_calls_by_provider).to eq("b" => { "winner-summary" => 1 },
                                                              "c" => { "winner-summary" => 1 })
        end
      end

      context "when the first provider fails over" do
        let(:routing) { { "mode" => "failover", "steps" => { "winner-summary" => { "providers" => %w[a b] } } } }

        it "uses the next provider's answer, and counts both providers' calls" do
          fakes["a"].error("winner-summary", status: 529)
          fakes["b"].reply("winner-summary", good)

          expect(summarize).to have_attributes(text: good, outcome: "used", entry: "b")
          expect(router.burndown.llm_calls_by_provider)
            .to eq("a" => { "winner-summary" => 1 }, "b" => { "winner-summary" => 1 })
          expect(router.down).to eq("a" => "llm_unavailable")
        end
      end

      context "when no provider is left" do
        let(:routing) { { "mode" => "failover", "steps" => { "winner-summary" => { "providers" => %w[a b] } } } }

        it "gives no text, with the last rule, when every pinned provider fails" do
          fakes.values_at("a", "b").each { it.error("winner-summary", status: 529) }

          expect(summarize).to have_attributes(text: nil, outcome: "failed", rule: "llm_unavailable", entry: nil)
        end

        it "gives no text without asking when every pinned provider is already down" do
          fakes.each_value { it.error("llm-rewrites", status: 529) }
          expect { router.ask(step: "llm-rewrites", messages: [{ role: :user, content: "x" }], max_tokens: 10) }
            .to raise_error(Quaack::Driver::LLM::Error)
          asked = fakes.values.sum { it.asks.size }

          expect(summarize).to have_attributes(text: nil, outcome: "failed", rule: "llm_unavailable")
          expect(fakes.values.sum { it.asks.size }).to eq(asked)
        end
      end
    end
  end

  describe "the provenance record" do
    let(:provenance) { Quaack::Driver::Provenance.new }

    def result(**) = described_class::Result.new(**)

    it "keeps the outcome, the entry, and a failed ask's rule, never the text" do
      provenance.winner_summary!(result(outcome: "used", text: "SENTINEL_TEXT", entry: "groq"))
      expect(provenance.record["winner_summary"]).to eq("outcome" => "used", "entry" => "groq")

      provenance.winner_summary!(result(outcome: "failed", rule: "llm_unavailable"))
      expect(provenance.record["winner_summary"]).to eq("outcome" => "failed", "rule" => "llm_unavailable")
      expect(JSON.generate(provenance.record)).not_to include("SENTINEL_TEXT")
    end

    it "keeps nothing for a run with no winner, and forgets an earlier ask's outcome" do
      provenance.winner_summary!(result(outcome: "rejected", entry: "groq"))
      provenance.winner_summary!(result(outcome: "no_winner"))

      expect(provenance.record).not_to have_key("winner_summary")
    end

    it "reads back only a well-formed outcome" do
      shape = Quaack::Driver::Provenance::Shape
      ok = { "outcome" => "empty", "entry" => "groq" }

      expect(shape.record("winner_summary" => ok)["winner_summary"]).to eq(ok)
      [{ "outcome" => "other" }, { "outcome" => "failed" }, { "outcome" => "used", "rule" => "llm_auth" },
       { "outcome" => "used", "entry" => "Bad Name" }, { "outcome" => "used", "text" => "x" }].each do |bad|
        expect(shape.record("winner_summary" => bad)).not_to have_key("winner_summary")
      end
    end
  end

  describe "the report" do
    def render(**) = Quaack::Driver::Report.render(payload, run_id: "RUN-1", **)

    def section(html) = html[%r{<section id="explanation"[^>]*>.*?</section>}m]

    let(:summary) { { "text" => good, "name" => "groq", "provider" => "openai_compatible", "model" => "m-1" } }

    it "opens the section with the summary under a label that names the LLM, its model, and what's measured" do
      body = section(render(summary:))

      expect(body).to match(%r{<h2>Why the winner reads fewer blocks</h2>\n<div class="llm-summary" id="llm-summary">})
      expect(body).to include("Summary written by an LLM (groq, <code>m-1</code>), not measured.")
        .and include("on the indexes your database already has. The measurements and plans below are the facts.")
        .and include("<p>#{good.gsub("'", "&#39;")}</p>")
      expect(body.index("Summary written by an LLM")).to be < body.index("How Postgres runs the original query now")
    end

    it "changes nothing else in the section, or the report, and without a summary reads as it did" do
      with = render(summary:)
      without = render

      expect(without).not_to include(%(<div class="llm-summary"))
      expect(without).not_to include("Summary written by")
      expect(with.sub(%r{<div class="llm-summary".*?</div>\n}m, "")).to eq(without)
      expect(render(summary: nil)).to eq(without)
      expect(render(summary: { "text" => "  " })).to eq(without)
    end

    it "escapes the text, the name, and the model" do
      html = render(summary: { "text" => "a <script>x</script> & \"q\"", "name" => "<i>n</i>", "model" => "<b>m</b>" })

      expect(section(html)).not_to match(/<script|<i>|<b>/)
      expect(section(html)).to include("a &lt;script&gt;x&lt;/script&gt; &amp; &quot;q&quot;",
                                       "&lt;i&gt;n&lt;/i&gt;, <code>&lt;b&gt;m&lt;/b&gt;</code>")
    end

    it "says an LLM wrote it when the entry isn't known" do
      body = section(render(summary: { "text" => good }))

      expect(body).to include("Summary written by an LLM (an LLM), not measured")
    end

    it "shows no summary in a report with no winner" do
      negative = payload.merge("top" => [], "negative" => { "declined" => [], "existing" => [] })
      html = Quaack::Driver::Report.render(negative, run_id: "RUN-1", summary:)

      expect(html).not_to include(%(<div class="llm-summary"))
      expect(html).not_to include("Why the winner reads fewer blocks")
    end

    it "lists the step in the LLM calls table" do
      html = render(llm_calls: { "winner-summary" => 1 }, llm: { "calls" => { "groq" => { "winner-summary" => 1 } } })

      expect(html).to include("<th scope=\"row\">Summary of why the winner reads fewer blocks</th>")
    end
  end

  describe "the report stage" do
    around do |example|
      Dir.mktmpdir do |home|
        @home = home
        example.run
      end
    end

    let(:run_id) { "20261008T120000Z-0123abcd" }
    let(:out) { File.join(@home, "report.html") }
    let(:done) do
      { "index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
        "rewrite_rules_applied" => true, "rewrites_generated" => true,
        **%w[arena_setup index_build baseline index_baseline candidate_runs minimax result_comparison
             selection].to_h { [it, true] } }
    end
    let(:fake) { FakeLLM.new }
    let(:router) do
      config = { "llms" => [{ "name" => "groq", "provider" => "anthropic", "model" => "m-1" }] }
      Quaack::Driver::LLM::Router.for(Quaack::Driver::LLM.providers(config, env: {}),
                                      [fake.client(burndown: Quaack::Driver::Burndown.new, model: "m-1",
                                                   max_retries: 0)])
    end
    let(:transport) do
      replies = { "status" => [{ "type" => "status", "entries" => done }], "report-payload" => [payload],
                  "index-feedback" => [{ "type" => "index_feedback", "revise" => false }] }
      Class.new do
        define_method(:call) { |subcommand, **| Data.define(:messages).new(messages: replies.fetch(subcommand, [])) }
      end.new
    end

    def run_pipeline
      Quaack::Driver::Pipeline.new(transport:, client: router, run_id:, out:, home: @home).run
      [File.read(out), Quaack::Driver::Provenance.open(@home, run_id).record]
    end

    # The report names the winner by the run's name for rewrite_1, not the payload's.
    let(:winner) { Quaack::Driver::RewriteNames.label(run_id, "rewrite_1") }
    let(:named_good) { good.gsub("Rewrite Steady Lute", winner) }

    it "asks once, prints the summary with its provider and model, and records and counts the ask" do
      fake.reply("winner-summary", named_good)
      html, record = run_pipeline

      expect(html).to include("Summary written by an LLM (groq, <code>m-1</code>), not measured.")
      expect(record["winner_summary"]).to eq("outcome" => "used", "entry" => "groq")
      expect(record.dig("llm_calls", "steps")).to eq("winner-summary" => 1)
      expect(html).to include("<th scope=\"row\">Summary of why the winner reads fewer blocks</th>")
      expect(fake.asks.size).to eq(1)
    end

    it "writes the report as it was, and records the failure, when the ask fails" do
      fake.error("winner-summary", status: 529)
      html, record = run_pipeline

      expect(html).not_to include(%(<div class="llm-summary"))
      expect(html).to include("<h2>Why the winner reads fewer blocks</h2>")
      expect(record["winner_summary"]).to eq("outcome" => "failed", "rule" => "llm_unavailable")
      expect(record["providers"].first).to include("name" => "groq", "down" => "llm_unavailable")
    end

    it "writes the report as it was, and records it, when the answer holds markup" do
      fake.reply("winner-summary", "#{winner} reads <b>fewer</b> blocks.")
      html, record = run_pipeline

      expect(html).not_to include(%(<div class="llm-summary"))
      expect(html).not_to include("<b>fewer")
      expect(record["winner_summary"]).to eq("outcome" => "rejected", "entry" => "groq")
    end

    it "asks nothing for a report with no winner" do
      payload["top"] = []
      html, record = run_pipeline

      expect(fake.asks).to be_empty
      expect(html).not_to include(%(<div class="llm-summary"))
      expect(record).not_to have_key("winner_summary")
    end
  end
end
