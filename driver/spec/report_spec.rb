# frozen_string_literal: true

require "tmpdir"
require "quaack/driver/report"

RSpec.describe Quaack::Driver::Report do
  def m(blocks, hit, stable: true)
    { "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "stable" => stable, "timed_out" => false }
  end

  # The report's two color themes as {name => {"--var" => "#hex"}}, from its stylesheet, and WCAG's contrast ratio
  # between two #hex colors.
  def theme_variables
    style = html[%r{<style>(.*?)</style>}m, 1]
    dark = style[/@media \(prefers-color-scheme: dark\) \{(.*?)\n  \}\n/m, 1]
    light = style[/^  :root \{(.*?)^  \}/m, 1]
    { light: light, dark: dark }.transform_values { |theme| theme.scan(/(--[a-z0-9-]+): (#\h{3,6})/).to_h }
  end

  # A #hex color (three or six digits) as its red, green and blue, 0 to 255.
  def rgb(hex)
    hex = hex.chars.drop(1).map { |c| c * 2 }.join if hex.length == 4
    hex.delete("#").scan(/\h\h/).map(&:hex)
  end

  def luminance(hex)
    r, g, b = rgb(hex).map { |c| c / 255.0 }.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  # How far apart two #hex colors are, as the straight-line distance between their RGB values.
  def distance(one, other) = Math.sqrt(rgb(one).zip(rgb(other)).sum { |a, b| (a - b)**2 })

  # A #hex color's hue in degrees, 0 up to 360, and the gap between two hues, 0 to 180 around the wheel.
  def hue(hex)
    red, green, blue = rgb(hex)
    Math.atan2(Math.sqrt(3) * (green - blue), (2 * red) - green - blue).*(180 / Math::PI) % 360
  end

  # A grey (white, black or near one) has no hue: atan2 of nothing gives 0, so a gap to it means nothing.
  def grey?(hex) = rgb(hex).minmax.then { |lo, hi| hi - lo } < 3

  def hue_gap(one, other)
    gap = (hue(one) - hue(other)).abs
    gap > 180 ? 360 - gap : gap
  end

  def contrast(one, other)
    hi, lo = [luminance(one), luminance(other)].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  def esc(text) = text.gsub("'", "&#39;")

  def render(payload, **) = described_class.render(payload, run_id: "RUN-1", **)

  def section(html, id) = html[%r{<section id="#{id}"[^>]*>.*?</section>}m]

  # SQL as the report sets it apart from the words around it.
  def sq(text) = %(<code class="sql">#{text}</code>)

  # A rule's name as the report links it to the rule's page (DESIGN.md's rewrite-rules).
  def docs = "https://github.com/benchub/quaack/blob/main/docs/transforms/"
  def link(rule) = %(<a href="#{docs}#{rule}.md" target="_blank" rel="noopener">#{rule}</a>)

  def fated(number, fate, **details)
    { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => nil, "rules" => nil,
      "fate" => fate, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
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
          "rules" => ["key_in_self_join"], "fate" => "ranked", "rule" => nil, "round" => nil,
          "after" => nil,
          "plan" => [{ "node" => "Index Scan", "relation" => "public.t", "index" => "t_a_idx", "est_rows" => 5,
                       "actual_rows" => nil, "selectivity" => 0.005, "depth" => 0, "shared_hit_blocks" => nil,
                       "shared_read_blocks" => nil, "actual_total_time" => nil, "actual_loops" => nil }],
          "untested_atoms" => ["a < $1"], "covered" => nil, "evidence" => nil }
      ],
      "indexes" => { "quaack_a" => { "ddl" => "CREATE INDEX ON public.t USING btree (created_at)", "size" => 8192,
                                     "covered_by" => { "name" => "t_created_at_id_idx", "size_bytes" => 40_960 },
                                     "sources" => %w[generator_one llm] },
                     "quaack_b" => { "ddl" => "CREATE INDEX ON public.t USING btree (a, b)", "size" => 16_384,
                                     "covered_by" => nil, "sources" => %w[generator_two] } },
      "original_plan" => [{ "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 50,
                            "actual_rows" => 50, "selectivity" => 0.05, "depth" => 0,
                            "shared_hit_blocks" => 1_200, "shared_read_blocks" => 34,
                            "actual_total_time" => 12.5, "actual_loops" => 1 }],
      "timed_out_count" => 2 }
  end

  let(:html) { render(payload) }

  let(:negative) do
    by = { "name" => "t_c_d_idx", "size_bytes" => 3 * 1024 * 1024,
           "definition" => "CREATE INDEX ON public.t USING btree (c, d) WHERE d = ?" }
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
    # The html less its links to rules' pages, which load nothing.
    def unlinked(html)
      html.gsub(/<a href="#{Regexp.escape(docs)}\w+\.md" target="_blank" rel="noopener">/, "")
    end

    # The one script the report has: the inline one that shows when it was generated in the reader's time.
    def scripts(out) = out.scan(%r{<script\b[^>]*>.*?</script>}m)

    def scriptless(out) = scripts(out).reduce(out) { |rest, script| rest.sub(script, "") }

    it "is one file of plain HTML and CSS, bar one inline script: no animation, nothing from the network" do
      expect(html).to start_with("<!DOCTYPE html>").and include("<style>")
      expect(scripts(html).size).to eq(1)
      expect(unlinked(scriptless(html)))
        .not_to match(/<script|<link|<img|<iframe|https?:|url\(|@import|animation|transition|src=/i)
    end

    it "loads nothing from the network in a negative report either" do
      expect(unlinked(scriptless(render(negative_payload))))
        .not_to match(/<script|<link|<img|https?:|url\(|@import|animation|src=/i)
    end

    it "keeps its one script inline and local: it only rewrites the generated-on time" do
      script = scripts(html).first
      expect(script).to start_with("<script>")
      expect(script).not_to match(/src=|https?:|fetch|XMLHttpRequest|import|eval|innerHTML|location|cookie|storage/i)
      expect(script).to include('querySelectorAll("time.local")', "toLocaleString(", "textContent")
    end

    describe "the generated-on line" do
      let(:at) { Time.utc(2026, 10, 19, 1, 11, 7) }

      def generated(out) = out[%r{<p class="generated">.*?</p>}m]

      it "says under the title when the report was generated, as UTC without a script" do
        out = render(payload, generated_at: at)
        expect(generated(out)).to eq('<p class="generated">Generated on <time class="local" ' \
                                     'datetime="2026-10-19T01:11:07Z">2026-10-19 01:11 UTC</time></p>')
        expect(out.index(generated(out))).to be > out.index("</h1>")
        expect(out.index(generated(out))).to be < out.index('<nav id="toc"')
      end

      it "turns a time in another zone into UTC" do
        out = render(payload, generated_at: Time.new(2026, 10, 19, 3, 11, 7, "+02:00"))
        expect(generated(out)).to include('datetime="2026-10-19T01:11:07Z">2026-10-19 01:11 UTC<')
      end

      it "uses the time it renders, when it isn't given one" do
        before = Time.now.utc
        stamp = Time.iso8601(generated(render(payload))[/datetime="([^"]+)"/, 1])
        expect(stamp).to be_between(Time.at(before.to_i), Time.now.utc)
      end

      it "shows it in the reader's own locale and time zone, in smaller text, with a script" do
        expect(scripts(html).first).to include("toLocaleString(undefined,")
        expect(html[%r{<style>(.*?)</style>}m, 1]).to match(/p\.generated \{[^}]*font-size: 0\.9rem/)
      end
    end

    describe "the table of contents" do
      def toc_targets(out) = out[%r{<nav id="toc".*?</nav>}m].to_s.scan(/href="#([\w-]+)"/).flatten
      def section_ids(out) = out.scan(/<section id="([\w-]+)"/).flatten

      it "links every rendered section, in order, and nothing else" do
        expect(toc_targets(html)).to eq(section_ids(html))
        expect(toc_targets(html)).to include("summary", "timeouts", "explanation", "burndown")
        expect(toc_targets(html)).not_to include("negative-result", "index-ideas", "quaack-bugs")
      end

      it "follows the sections a negative report renders" do
        out = render(negative_payload)
        expect(toc_targets(out)).to eq(section_ids(out))
        expect(toc_targets(out)).to include("negative-result")
        expect(toc_targets(out)).not_to include("explanation")
      end

      it "links the rule-bug section first when a rule made a wrong rewrite" do
        bugs = [{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"], "step" => "rewrite-test" }]
        out = render(payload.merge("rule_bugs" => bugs))
        expect(toc_targets(out)).to eq(section_ids(out))
        expect(toc_targets(out).first).to eq("quaack-bugs")
      end

      it "leaves out the timeouts section when nothing timed out" do
        out = render(payload.merge("timed_out_count" => 0))
        expect(toc_targets(out)).to eq(section_ids(out))
        expect(toc_targets(out)).not_to include("timeouts")
      end

      let(:style) { html[%r{<style>(.*?)</style>}m, 1] }
      let(:breakpoint) { style[/@media screen and \(min-width: ([\d.]+rem)\) \{/, 1].to_s }
      let(:wide) { style[/@media screen and \(min-width: [\d.]+rem\) \{(.*?)\n  \}\n/m, 1].to_s }

      # A rule's declarations in css, as {property => value}.
      def rule(css, selector)
        css[/^\s*#{Regexp.escape(selector)} \{([^}]*)\}/, 1].to_s.scan(/([a-z-]+): ([^;]+);/).to_h
      end

      def rem(value) = value[/\A([\d.]+)rem\z/, 1]&.to_f

      it "sits fixed in the left margin on a wide window, inline otherwise, and never in print" do
        expect(rule(wide, "nav#toc")).to include("position" => "fixed", "max-height" => "calc(100vh - 2rem)",
                                                 "overflow-y" => "auto")
        expect(style[/@media print \{(.*?)\n  \}\n/m, 1]).to match(/nav#toc \{ display: none; \}/)
        expect(html.index('<nav id="toc"')).to be > html.index("<h1>")
      end

      # Review of 20261019-1: printed in landscape, the page kept the wide margin for the hidden contents.
      it "keeps the wide layout to the screen, so print gets no margin for the hidden contents" do
        expect(style).to match(/@media screen and \(min-width: [\d.]+rem\) \{/)
        expect(style).not_to match(/@media \(min-width/)
      end

      it "has a border in the page's rule color" do
        expect(rule(style, "nav#toc")).to include("border" => "1px solid var(--rule)")
      end

      # Task 20261019-1: the margin grew with the window, so a wider window showed no more of a wide plan.
      it "keeps the left margin as wide as the contents, and gives the rest of a wide window to the report" do
        toc = rule(wide, "nav#toc")
        body = rule(wide, "body")
        expect(style).not_to include("100vw")
        expect(body).to include("max-width" => "none")
        expect(rem(toc["width"])).to be_between(10, 16)
        expect(rem(body["margin-left"])).to be > rem(toc["left"]) + rem(toc["width"])
        expect(rem(body["margin-left"])).to be <= rem(toc["left"]) + rem(toc["width"]) + 2
      end

      # Task 20261019-2: just above a 64rem breakpoint, the margin left the prose narrower than the centered layout.
      it "switches to the margin only once the window fits the margin, the padding, and the full readable width" do
        padding = rule(style, "body")["padding"].to_s.split.map { |v| v == "0" ? 0.0 : rem(v) }
        horizontal = padding.size == 1 ? padding[0] * 2 : padding[1] + padding.fetch(3, padding[1])
        readable = rem(rule(wide, "p, ul, svg.sankey")["max-width"].to_s)
        fits = rem(rule(wide, "body")["margin-left"].to_s) + horizontal + readable
        expect(rem(breakpoint)).to be_between(fits, fits + 2)
      end

      it "keeps the prose and the diagrams to a readable width, but not the tables or the SQL" do
        expect(rule(wide, "p, ul, svg.sankey")).to include("max-width" => "62rem")
        expect(wide).not_to match(/table[^{]*\{[^}]*max-width|pre[^{]*\{[^}]*max-width/)
      end
    end

    describe "the color theme" do
      let(:style) { html[%r{<style>(.*?)</style>}m, 1] }
      let(:dark) { style[/@media \(prefers-color-scheme: dark\) \{(.*?)\n  \}\n/m, 1] }
      let(:light) { style[/^  :root \{(.*?)^  \}/m, 1] }
      let(:names) { light.scan(/(--[a-z-]+):/).flatten }

      it "defines the colors once on :root and redefines every one in the dark block" do
        expect(names.size).to be > 25
        expect(names - dark.scan(/(--[a-z-]+):/).flatten).to eq([])
        expect(dark.scan(/(--[a-z-]+):/).flatten - names).to eq([])
      end

      it "gives every color variable a different dark value from its light one, bar the page-matched panels" do
        pair = ->(css) { css.scan(/(--[a-z-]+): (#\h+)/).to_h }
        same = pair.call(light).select { |k, v| pair.call(dark)[k] == v }.keys
        expect(same).to eq([])
      end

      it "leaves no color literal outside :root and the dark block" do
        rest = style.sub(light, "").sub(dark, "")
        expect(rest).not_to match(/:[^;{}]*#\h{3,8}\b|rgba?\(|hsla?\(|(?<![-\w])(white|black)(?![-\w])/)
        expect(rest).to include("var(--bg)").and include("var(--text)")
      end

      it "uses only variables that :root defines" do
        used = (style + html[%r{</style>.*}m]).scan(/var\((--[a-z-]+)\)/).flatten.uniq
        # Set per fold color by details.query and details.rose, and per kind by .stripe-*.
        folds = %w[--fold-edge --fold-accent --stripe]
        expect(used - names - folds).to eq([])
        expect(style.scan(/^  details\.(?:query|rose) \{ --fold-edge: var/).size).to eq(2)
        expect(names).to include("--rose-edge", "--rose-accent")
      end

      it "gives every stage color and the Sankey's grey a variable that :root defines" do
        style_module = Quaack::Driver::Report::StageStyle
        grey = Quaack::Driver::Report::SankeyDrawing::GREY
        vars = (style_module::COLORS.values + [style_module::BLUE, grey]).flat_map do |v|
          v.scan(/var\((--[a-z-]+)\)/).flatten
        end
        expect(style_module::COLORS.values).to all(match(/\Avar\(--st-[a-z]+\)\z/))
        expect(vars.uniq - names).to eq([])
      end

      # Task 20261012-6: the Sankey's text colors, once the funnel's, keep their values in both themes.
      it "gives the Sankey's text its own variables, with the same light and dark values the funnel's had" do
        expect(light).to include("--sankey-text: #1c2430; --sankey-count: #515b69;")
        expect(dark).to include("--sankey-text: #e6eaf0; --sankey-count: #a9b3c1;")
        expect(style).not_to include("--funnel-")
        expect(style).not_to include("--known-line")
        expect(style).not_to include("--hatch")
        expect(style).to include("svg.sankey text { font: 12px -apple-system, \"Segoe UI\", Helvetica, Arial, " \
                                 "sans-serif; fill: var(--sankey-count); }")
        expect(style).to include("svg.sankey text.layer { font-size: 13px; font-weight: 600; " \
                                 "fill: var(--sankey-text); }")
      end

      it "paints the Sankey diagrams from variables, with no hex color in the body" do
        body = html[%r{</style>.*}m]
        expect(body).not_to match(/#\h{6}\b/)
        expect(render(negative_payload)).to include("<style>")
      end
    end

    it "sets inline SQL apart in monospace on a subtle background, wrapping long DDL inside the page" do
      rule = html[/^\s*code\.sql\s*\{[^}]*\}/]
      expect(rule).to match(/background:\s*var\(--code-bg\)/).and match(/overflow-wrap:\s*break-word/)
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

    it "puts the verdict first, then the queries, the ranking, the indices, who proposed what, and the burndown" do
      ids = html.scan(/<section id="([a-z-]+)"[^>]*>/).flatten
      expect(ids).to eq(%w[summary queries ranking timeouts explanation indexes accountability burndown])
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
    def verdict(html) = section(html, "summary")

    # The table's rows as text: each row's cells, joined by " | ".
    def verdict_rows(html)
      verdict(html)[%r{<tbody>.*</tbody>}m].scan(%r{<tr.*?</tr>}m).map do |row|
        row.scan(%r{<t[dh][^>]*>(.*?)</t[dh]>}m).flatten.map { it.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip }
           .join(" | ")
      end
    end

    it "heads the verdict by how much the best row beats the original, and ranks one row per kind by improvement" do
      expect(verdict(html)).to include("<h2>The verdict: substantial improvements possible</h2>")
      expect(verdict_rows(html)).to eq(
        ["Best rewrite, with the same indices Rewrite Vivid Cove with no new indices | 300 | 0 | 70%",
         "The original query, with new indices The original query with new indices | 400 | +8 kB | 60%",
         "The original query, with the same indices | 1,000 | 0 | 0%",
         "Best rewrite, with new indices | " \
         "&#9888; No rewrite with new indices beat the original"]
      )
    end

    it "leaves index definitions out of the verdict, and still shows each in the candidates' tables" do
      sentinel = "sentinel_col_7f3a"
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.t USING btree (#{sentinel})"
      out = render(payload)
      expect(verdict(out)).not_to include(sentinel)
      expect(verdict(out)).to include("The original query with new indices")
      expect(out[%r{<article class="candidate">.*?ith new indices:</h3>.*?</article>}m]).to include(sentinel)
    end

    it "calls 30% fewer blocks substantial and anything less minor" do
      payload["top"][0]["slow_blocks"] = 700
      expect(verdict(render(payload))).to include("The verdict: substantial improvements possible")
      payload["top"][0]["slow_blocks"] = 701
      expect(verdict(render(payload))).to include("The verdict: minor improvements possible")
    end

    describe "links" do
      let(:backgrounds) do
        %w[--bg --panel --head-bg --code-bg --summary-bg --good-bg --minor-bg --bug-bg
           --baseline-bg]
      end

      it "are the accent color, with their own visited and hover colors" do
        style = html[%r{<style>(.*?)</style>}m, 1]
        expect(style[/^  a \{[^}]*\}/]).to include("color: var(--accent)")
        expect(style[/^  a:visited \{[^}]*\}/]).to include("color: var(--link-visited)")
        expect(style[/^  a:hover \{[^}]*\}/]).to include("color: var(--link-hover)")
        expect(style[/^  a:hover \{[^}]*\}/]).to include("text-decoration-thickness")
        theme_variables.each_value do |v|
          expect([v["--accent"], v["--link-visited"], v["--link-hover"]].uniq.size).to eq(3)
        end
      end

      it "read at 4.5:1 or better on the page and on every box and table a link can sit in, in both themes" do
        theme_variables.each do |name, v|
          %w[--accent --link-visited --link-hover].each do |link|
            backgrounds.each do |bg|
              expect(contrast(v[link], v[bg])).to be >= 4.5, "#{name} #{link} on #{bg}"
            end
          end
        end
      end
    end

    describe "the verdict section's color" do
      def summary_open(out)
        out[/<section id="summary"[^>]*>/]
      end

      def css(out, kind)
        out[/#summary\.#{kind} \{[^}]*\}/]
      end

      it "is green for substantial improvements and no other kind" do
        out = render(payload)
        expect(summary_open(out)).to eq('<section id="summary" class="substantial">')
        expect(css(out, "substantial")).to include("var(--good-bg)", "var(--good-edge)")
      end

      it "is cream for minor improvements and no other kind" do
        payload["top"][0]["slow_blocks"] = 701
        out = render(payload)
        expect(summary_open(out)).to eq('<section id="summary" class="minor">')
        expect(css(out, "minor")).to include("var(--minor-bg)", "var(--minor-edge)")
      end

      it "keeps the cream stripe at 3:1 or better against the cream background and the page, in both themes" do
        theme_variables.each_value do |v|
          expect(contrast(v["--minor-edge"], v["--minor-bg"])).to be >= 3.0
          expect(contrast(v["--minor-edge"], v["--bg"])).to be >= 3.0
        end
      end

      # Task 20261011-14 item 3: the fold's Expand/Collapse label and stripe sit on the page, not on a tint.
      it "keeps each fold's label at 4.5:1 and its stripe at 3:1 against the page, in both themes" do
        theme_variables.each do |name, v|
          %w[--query-accent --rose-accent].each { |c| expect(contrast(v[c], v["--bg"])).to be >= 4.5, "#{name} #{c}" }
          %w[--query-edge --rose-edge].each { |c| expect(contrast(v[c], v["--bg"])).to be >= 3.0, "#{name} #{c}" }
        end
      end

      it "stays blue when QUAACK found nothing" do
        out = render(negative_payload)
        expect(summary_open(out)).to eq('<section id="summary" class="nothing">')
        expect(css(out, "nothing")).to be_nil
      end
    end

    it "says QUAACK found nothing that could help when nothing beat the original, and what it tried" do
      out = verdict(render(negative_payload))
      expect(out).to include("The verdict: QUAACK found nothing that could help")
      expect(out).to include("It built and measured 2 indices and kept 1 rewrite.")
      expect(verdict_rows(render(negative_payload)).map { it.split(" | ").first }).to eq(
        ["The original query, with the same indices", "Best rewrite, with new indices",
         "Best rewrite, with the same indices", "The original query, with new indices"]
      )
    end

    it "gives a kind with no candidate a ⚠ and a hover that says more, from what QUAACK measured" do
      out = verdict(render(negative_payload))
      expect(out).to include("<td colspan=\"3\" title=\"QUAACK measured 1 candidate of this kind, and none made " \
                             "the ranking. The ranking section says why.\"><span class=\"warn\">&#9888; No " \
                             "rewrite beat the original without an index</span>")
      expect(out).to include("&#9888; No new index beat the original query")
    end

    # Task 20261018-31: a shared pairing candidate-runs skipped wasn't measured.
    it "doesn't count a skipped shared pairing among what QUAACK measured of its kind" do
      skipped = { "label" => "rewrite_1:shared:1", "search" => "rewrite_1", "indexes" => ["quaack_a"],
                  "timed_out" => false, "skipped" => true, "measurements" => nil, "verdicts" => nil }
      out = verdict(render(negative_payload.merge("labels" => negative_payload["labels"] + [skipped])))
      expect(out).to include("title=\"QUAACK measured 1 candidate of this kind, and none made the ranking. The " \
                             "ranking section says why.\"><span class=\"warn\">&#9888; No rewrite with new indices")
    end

    it "says no index was found or no rewrite survived when nothing of that kind was measured" do
      payload["top"].shift(2)
      payload["labels"].select! { it["label"] == "rewrite_1:top:1" }
      out = verdict(render(payload))
      expect(out).to include("The verdict: QUAACK found nothing that could help")
      expect(out).to include("&#9888; No new index found that the original query could use")
      expect(out).to include(%(title="QUAACK built 2 indices in all, and none was measured with the original ) +
                             %(query."))
      expect(out).to include("&#9888; No rewrite was measured with no new indices")
      expect(out).to include("QUAACK kept 1 rewrite, and none was measured with no new indices.")
    end

    it "doesn't say no rewrite survived when rewrites were kept but none was measured with new indices" do
      payload["labels"].reject! { it["label"] == "rewrite_1:top:1" }
      out = verdict(render(payload))
      expect(out).to include("&#9888; No rewrite was measured with new indices")
      expect(out).not_to include("No rewrite survived testing")
      payload["rewrites"] = []
      payload["labels"].reject! { it["search"] == "rewrite_1" }
      expect(verdict(render(payload))).to include("&#9888; No rewrite survived testing")
    end

    it "says a new-indexes row's added size isn't recorded when its label has no indices or no entry" do
      payload["labels"][0]["indexes"] = []
      expect(verdict_rows(render(payload))[1]).to include("| not recorded |")
      payload["labels"].shift
      row = verdict_rows(render(payload)).grep(/\Athe original query, with new indices/i).first
      expect(row).to include("| not recorded |")
    end

    it "adds up the built size of every new index a candidate ran with, and says so when one isn't recorded" do
      payload["labels"][0]["indexes"] = %w[quaack_a quaack_b]
      expect(verdict_rows(render(payload))[1]).to include("| +24 kB |")
      payload["indexes"]["quaack_b"]["size"] = nil
      expect(verdict_rows(render(payload))[1]).to include("| not recorded |")
    end

    # Task 20261009-8.
    describe "a suggested drop" do
      let(:drops) do
        [{ "name" => "t_old_idx", "size_bytes" => 10_240, "idx_scan" => 1234 },
         { "name" => "t_older_idx", "size_bytes" => 2048, "idx_scan" => 1 }]
      end

      before do
        payload["labels"][0]["indexes"] = %w[quaack_a quaack_b]
        payload["labels"][0]["suggested_drops"] = drops
      end

      def candidate_section(html)
        html[%r{<article class="candidate">(?:(?!</article>).)*?ith new indices:</h3>.*?</article>}m]
      end

      it "subtracts the dropped indices' sizes from the row's index change, and goes negative if they outweigh it" do
        expect(verdict_rows(render(payload))[1]).to include("| +12 kB |")
        drops[0]["size_bytes"] = 40_960
        expect(verdict_rows(render(payload))[1]).to include("| -18 kB |")
      end

      it "says a row's index change isn't recorded when a dropped index's size isn't" do
        drops[1]["size_bytes"] = nil
        expect(verdict_rows(render(payload))[1]).to include("| not recorded |")
      end

      it "names each index in the ranked candidate's section, with its size and scan count, and warns" do
        section = candidate_section(render(payload))

        expect(section).to include("Other queries may use them, so check before you drop one.")
        expect(section).to include("#{sq("t_old_idx")} (10 kB), production&#39;s statistics show 1,234 scans")
        expect(section).to include("#{sq("t_older_idx")} (2 kB), production&#39;s statistics show 1 scan<")
        expect(section).to include("QUAACK doesn't drop anything.", "a replica's use isn't in them")
      end

      it "says so when an index's scan count isn't recorded, and shows nothing for a label with no drops" do
        drops[0]["idx_scan"] = nil
        expect(candidate_section(render(payload))).to include("its scan count isn&#39;t known")
        payload["labels"][0].delete("suggested_drops")
        expect(render(payload)).not_to include("QUAACK doesn't drop anything.")
        expect(verdict_rows(render(payload))[1]).to include("| +24 kB |")
      end
    end

    it "says over 99% fewer, as the ranked tables do, when rounding would say all of them" do
      payload["top"][0]["slow_blocks"] = 12
      payload["original_measurements"]["slow"] = m(5120, 0)
      expect(verdict_rows(render(payload)).first).to end_with("| 12 | 0 | over 99%")
    end

    it "says a candidate won where the original timed out, and warns about the timeout" do
      payload["original_measurements"]["slow"] = { "timed_out" => true }
      payload["infinite_sets"] = ["slow"]
      out = render(payload)
      expect(verdict(out)).to include("The verdict: substantial improvements possible")
      expect(verdict_rows(out).first).to end_with("| 300 | 0 | the original query timed out")
      expect(verdict_rows(out)[2]).to eq("The original query, with the same indices | timed out | 0 | 0%")
      expect(verdict(out)).to include("&#9888; The original query timed out on the slow values")
    end

    it "gives each caveat a short ⚠ line that links to its detail, and none when there's nothing to say" do
      expect(verdict(html)).to include('<li class="warn">&#9888; 2 measurement runs of candidates timed out, ' \
                                       'and QUAACK dropped those candidates. <a href="#timeouts">Details</a></li>')
      payload["timed_out_count"] = 0
      expect(verdict(render(payload))).not_to include("&#9888; 2")
      expect(verdict(render(payload))).not_to include("verdict-caveats")
    end

    # Task 20261008-34.
    it "says which statistics the production role couldn't see, and nothing when it saw them all" do
      payload["hidden_statistics"] = { "indexes" => %w[orders_lower_idx orders_expr_idx], "extended_statistics" => 2 }
      expect(verdict(render(payload))).to include(
        "&#9888; Your role on the production server couldn&#39;t see the statistics of 2 extended statistics " \
        "objects and of these expression indices: <code class=\"sql\">orders_lower_idx</code>, " \
        "<code class=\"sql\">orders_expr_idx</code>, so QUAACK&#39;s estimates for those may be off. A role that " \
        "owns the tables can see them. <a href=\"#hidden-statistics\">Details</a>"
      )
      payload["hidden_statistics"] = { "indexes" => [], "extended_statistics" => 1 }
      expect(verdict(render(payload))).to include("couldn&#39;t see the statistics of 1 extended statistics object, so")
      payload["hidden_statistics"] = { "indexes" => ["orders_lower_idx"], "extended_statistics" => 0 }
      expect(verdict(render(payload))).to include(
        "couldn&#39;t see the statistics of this expression index: <code class=\"sql\">orders_lower_idx</code>, so"
      )
      [{ "indexes" => [], "extended_statistics" => 0 }, nil].each do |hidden|
        payload["hidden_statistics"] = hidden
        expect(verdict(render(payload.compact))).not_to include("couldn&#39;t see")
      end
    end

    # Task 20261009-28. Each caveat's link must land on a section that talks about it.
    # The two timed-out caveats still land on the ranking section, which is silent about
    # them: task 20261009-29 gives them a section of their own, and the subject check
    # for them goes in then. Until then only the target's existence is asserted.
    describe "the caveat links" do
      let(:caveat_payload) do
        payload.merge("timed_out_count" => 1, "infinite_sets" => %w[slow typical],
                      "labels" => payload["labels"] + [timed_out_label, measured_timed_out_label],
                      "hidden_statistics" => { "indexes" => ["orders_lower_idx"], "extended_statistics" => 2 },
                      "tablespace_moves" => ["public.orders"])
      end
      let(:out) { render(caveat_payload) }
      let(:timed_out_label) do
        { "label" => "rewrite_1:top:2", "search" => "rewrite_1", "indexes" => ["quaack_a"], "timed_out" => true,
          "measurements" => nil, "verdicts" => nil }
      end
      let(:measured_timed_out_label) do
        { "label" => "original:top:2", "search" => "original", "indexes" => ["quaack_b"], "timed_out" => true,
          "measurements" => { "slow" => { "timed_out" => true }, "typical" => m(100, 100) }, "verdicts" => nil }
      end
      # What each link target must mention for the caveats that point at it. A caveat with a new
      # target has no entry, so the example below fails on it until someone says what it must name.
      let(:subjects) do
        { "timeouts" => ["Rewrite Vivid Cove with a new index", "Any candidate that finished there counts as better"],
          "hidden-statistics" => ["orders_lower_idx"], "ranking" => [sq("public.orders")] }
      end

      it "lands every caveat the verdict gives on a section that exists and names its subject" do
        list = Quaack::Driver::Report::View.new(caveat_payload, "run").caveats
        items = verdict(out).scan(%r{<li class="warn">(.*?)</li>}m).flatten
        expect(list.size).to be >= 4
        expect(items.size).to eq(list.size)
        list.zip(items).each do |(_, target), item|
          expect(item).to include(%(href="##{target}"))
          body = out[%r{<section id="#{Regexp.escape(target)}"[^>]*>.*?</section>}m] ||
                 out[%r{<div id="#{Regexp.escape(target)}"[^>]*>.*?</div>}m]
          expect(body).not_to be_nil
          expect(body).to include(*subjects.fetch(target))
        end
      end

      # Task 20261016-1: the hidden-statistics caveat lands on the subsection that explains it,
      # inside the indexes section, not on the top of the indexes section.
      it "links the hidden-statistics caveat to its subsection inside the indices section" do
        item = verdict(out).scan(%r{<li class="warn">(.*?)</li>}m).flatten.find { it.include?("orders_lower_idx") }
        expect(item).to include('href="#hidden-statistics"')
        expect(section(out, "indexes")).to include('<div id="hidden-statistics"')
      end

      it "says how many extended statistics objects and which indices are hidden, for either alone or both" do
        hidden = lambda do |value|
          caveat_payload["hidden_statistics"] = value
          section(render(caveat_payload), "indexes")[%r{<div id="hidden-statistics".*?</div>}m]
        end
        both = hidden.call({ "indexes" => ["orders_lower_idx"], "extended_statistics" => 2 })
        expect(both).to include("of 2 extended statistics objects and of this expression index: " \
                                "#{sq("orders_lower_idx")}.")
        only_extended = hidden.call({ "indexes" => [], "extended_statistics" => 1 })
        expect(only_extended).to include("of 1 extended statistics object.")
        expect(only_extended).not_to include("expression index")
      end

      it "explains the timed-out runs in a section of their own, from the payload's labels and sets" do
        sec = section(out, "timeouts")
        expect(sec).to include("<h2>", "1 measurement run of candidates", "Rewrite Vivid Cove with a new index",
                               "</code> timed out.</li>", "dropped", "aren't ranked", "didn't measure them to the end",
                               "The original query timed out on the slow and typical values",
                               "Any candidate that finished there counts as better")
        expect(sec.scan("<li>").size).to eq(1)
        expect(sec).not_to include("The original query with a new index")
        caveat_payload["labels"][-2]["label"] = "<script>"
        escaped = section(render(caveat_payload), "timeouts")
        expect(escaped).to include("&lt;script&gt;")
        expect(escaped).not_to include("<script>")
      end

      # Task 20261018-31.
      it "lists each shared pairing QUAACK skipped because its rewrite timed out with no new indices" do
        skipped = { "label" => "rewrite_1:shared:1", "search" => "rewrite_1", "indexes" => ["quaack_a"],
                    "timed_out" => false, "skipped" => true, "measurements" => nil, "verdicts" => nil }
        sec = section(render(caveat_payload.merge("labels" => caveat_payload["labels"] + [skipped])), "timeouts")
        expect(sec.scan("<li>").size).to eq(2)
        expect(sec).to include("QUAACK didn&#39;t measure these pairings with another candidate&#39;s indices, " \
                               "since their rewrite timed out with no new indices:")
        expect(sec[%r{<ul id="skipped-runs">.*?</ul>}m].scan("<li>").size).to eq(1)
        expect(sec[%r{<ul id="skipped-runs">.*?</ul>}m]).to include("<li>Rewrite Vivid Cove with a new index on ")
        expect(section(out, "timeouts")).not_to include("skipped-runs")
      end

      it "leaves the section out when nothing timed out" do
        expect(render(caveat_payload.merge("timed_out_count" => 0, "infinite_sets" => [])))
          .not_to include('id="timeouts"')
      end

      it "explains the hidden statistics in the indices section, from the payload's names and count only" do
        note = section(out, "indexes")[%r{<div id="hidden-statistics".*?</div>}m]
        expect(note).to include("2 extended statistics objects", sq("orders_lower_idx"), "LLM&#39;s index ideas",
                                "can&#39;t read its columns", "let QUAACK read these statistics", "owns the tables")
        expect(note).not_to include("estimate", "run server", "copy", "real reads", "which ideas to try")
        caveat_payload["hidden_statistics"] = { "indexes" => ["<b>x</b>"], "extended_statistics" => 0 }
        note = section(render(caveat_payload), "indexes")[%r{<div id="hidden-statistics".*?</div>}m]
        expect(note).to include("&lt;b&gt;x&lt;/b&gt;")
        expect(note).not_to include("<b>x")
        expect(note).not_to include("extended statistics object")
        caveat_payload["hidden_statistics"] = { "indexes" => [], "extended_statistics" => 0 }
        expect(section(render(caveat_payload), "indexes")).not_to include("hidden-statistics")
      end

      # Task 20261010-17: a table that sits in another tablespace on the run server than in
      # production is a warning, by the table's name only. No tablespace's name reaches the driver.
      it "warns, by table name only, of tables that sit elsewhere on the run server" do
        caveat_payload["tablespace_moves"] = ["public.orders", 'public."Odd"']
        html = render(caveat_payload)
        expect(verdict(html)).to include(
          "&#9888; 2 of the query&#39;s tables sit in a different tablespace on the run server than in " \
          "production: #{sq("public.orders")}, #{sq("public.&quot;Odd&quot;")}. QUAACK&#39;s block counts may " \
          "not match production&#39;s. <a href=\"#ranking\">Details</a>"
        )
        note = section(html, "ranking")[%r{<div id="tablespace-moves".*?</div>}m]
        expect(note).to include("Tables that sit elsewhere on the run server", sq("public.orders"),
                                sq("public.&quot;Odd&quot;"), "TOAST table", "indices", "plans",
                                "pg_class.reltablespace")
        caveat_payload["tablespace_moves"] = ["public.<b>x</b>"]
        html = render(caveat_payload)
        expect(verdict(html)).to include("1 of the query&#39;s tables sits", sq("public.&lt;b&gt;x&lt;/b&gt;"))
        expect(html).not_to include("<b>x")
        [[], nil].each do |moves|
          caveat_payload["tablespace_moves"] = moves
          html = render(caveat_payload.compact)
          expect(html).not_to include("tablespace-moves", "different tablespace")
        end
      end
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
        "<h3>The original query</h3></summary>\n<pre class=\"sql\"><code>SELECT id\nFROM t\nWHERE\n  " \
        "created_at &gt; (now() - $1)\n  " \
        "AND b IN (\n    SELECT b\n    FROM u\n    WHERE c = $2\n  )</code></pre>"
      )
      expect(queries.index("<h3>The original query</h3>")).to be < queries.index("<h3>Rewrite Vivid Cove</h3>")
    end

    it "shows every rewrite, ranked or not, pretty-printed, in order" do
      payload["rewrites"] << fated(2, "same_plans", sql: "SELECT id FROM t WHERE b = $1 LIMIT 5")
      opening = %(<details class="fold query" id="rewrite-(\\d+)">\n<summary>)
      expect(queries.scan(%r{<article class="rewrite">#{opening}<h3>([^<]+)</h3>}))
        .to eq([["1", "Rewrite Vivid Cove"], ["2", "Rewrite Smooth Kayak"]])
      expect(queries).to include("<code>SELECT id\nFROM t\nWHERE a &lt; $1\nORDER BY id</code>")
      expect(queries).to include("<code>SELECT id\nFROM t\nWHERE b = $1\nLIMIT 5</code>")
    end

    it "keeps each query's SQL behind its own collapsed section, with the rewrite's name, source, and fate on top" do
      payload["rewrites"] << fated(2, "same_plans", sql: "SELECT id FROM t WHERE b = $1 LIMIT 5", source: "llm")
      same_plans = esc("Postgres plans it exactly as it plans the original query, so it can't run any differently. " \
                       "QUAACK didn't test it further.")
      blocks = queries.scan(%r{<details class="fold query"[^>]*>\s*<summary>(.*?)</summary>(.*?)</details>}m)
      expect(blocks.map(&:first)).to eq(
        ["<h3>The original query</h3>",
         "<h3>Rewrite Vivid Cove</h3> <span class=\"source\">Where it came from: transform " \
         "rule #{link("key_in_self_join")}.</span> <span class=\"fate\">What became of it: It beat the original " \
         "query and is ranked below.</span>",
         "<h3>Rewrite Smooth Kayak</h3> <span class=\"source\">Where it came from: suggested by the LLM (its " \
         "model wasn&#39;t recorded).</span> " \
         "<span class=\"fate\">What became of it: #{same_plans}</span>"]
      )
      expect(blocks.map { it.last.scan('<pre class="sql">').size }).to eq([1, 1, 1])
      expect(queries.scan('<pre class="sql">').size).to eq(3)
      expect(queries).not_to match(/<details[^>]*\bopen\b/)
    end

    describe "a warning inside a rewrite's collapsed section" do
      def warning(atoms: [], empirical: nil, covered: nil, unchanged: nil)
        payload["rewrites"].first.merge!("untested_atoms" => atoms, "empirical" => empirical, "covered" => covered,
                                         "untested_unchanged" => unchanged)
        summary = section(render(payload), "queries")[%r{<h3>Rewrite Vivid Cove</h3>.*?</summary>}m]
        summary[%r{<span class="warn">(.*?)</span>}, 1]
      end

      let(:assumed) do
        [{ "table" => "public.s", "column" => "c", "references_table" => "public.a", "type_column" => "t",
           "id_column" => "i" }]
      end

      it "flags it in the summary line, so a closed section still shows it" do
        expect(warning(empirical: assumed)).to eq("Read it with care: it relies on what your data holds today.")
      end

      # Task 20261016-2: every tested rewrite had some condition the test data never made both true and false,
      # so the caution said nothing. The untested conditions stay internal, for the LLM's test data to aim at.
      it "never cautions about conditions the test data didn't make both true and false" do
        expect(warning(atoms: ["a < $1"])).to be_nil
        expect(warning(atoms: ["a < $1", "t.b IS NULL"], covered: ["a < $1"], unchanged: [])).to be_nil
        expect(warning(atoms: ["a < $1"], empirical: assumed))
          .to eq("Read it with care: it relies on what your data holds today.")
      end

      it "flags nothing when the section holds neither warning" do
        expect(warning).to be_nil
        expect(warning(atoms: [7], empirical: [])).to be_nil
      end
    end

    it "points each link into the queries at the collapsed section, which opens to show it" do
      expect(html).to include('<details class="fold query" id="rewrite-1">')
      expect(html.scan(' id="rewrite-1"').size).to eq(1)
      expect(html).to include("details.fold:target::details-content { content-visibility: visible; }")
    end

    it "styles each fold with a stripe from its color, violet for a query, unlike the blue verdict" do
      expect(html).to include("details.query { --fold-edge: var(--query-edge); --fold-accent: var(--query-accent); }")
      expect(html).to include("details.fold { border-left: 5px solid var(--fold-edge);")
      expect(html).to include("scroll-margin-top: 0.5rem; }")
    end

    # Task 20261011-14 item 3: the tint was narrower than the section's contents, so the stripe alone marks it.
    it "tints no fold's background, in the light or the dark theme, and keeps only the stripe" do
      style = html[%r{<style>(.*?)</style>}m, 1]
      fold = style[/^  details\.fold \{[^}]*\}/]
      expect(fold).to include("border-left: 5px solid var(--fold-edge)")
      expect(fold).not_to include("background")
      expect(style[/^  details\.query \{[^}]*\}/]).not_to match(/background|-bg/)
      expect(style[/^  details\.rose \{[^}]*\}/]).not_to match(/background|-bg/)
      expect(style).not_to match(/--fold-bg|--rose-bg|--query-bg/)
      expect(style.scan(/--(?:rose|query)-(?:edge|accent):/).size).to eq(8)
    end

    it "pins an open fold's summary bar to the top of the window, in the page's background" do
      expect(html).to include("details.fold > summary { position: sticky; top: 0; z-index: 1;")
      expect(html).to include("background: var(--bg); padding: 0.5rem 7rem 0.5rem 0;")
    end

    it "labels the bar Collapse while open and Expand while closed, with no script" do
      expect(html).to include('details.fold > summary::after { content: "\\25BC  Expand";')
      expect(html).to include('details.fold[open] > summary::after { content: "\\25B2  Collapse"; }')
      expect(html.scan("<script").size).to eq(1)
      expect(html[%r{<script>.*?</script>}m]).not_to match(/details|open|Collapse|Expand/)
    end

    it "outlines the section a link lands on, so it stands out from the others" do
      expect(html).to include("details.fold:target { outline: 2px solid var(--accent); outline-offset: 0.25rem; }")
    end

    it "colors the not-ranked and index-idea fold stripes rose, with its own light and dark values" do
      expect(html).to include("details.rose { --fold-edge: var(--rose-edge); --fold-accent: var(--rose-accent); }")
      expect(html).to include("--rose-edge: #b02a5b; --rose-accent: #8e1f48;")
      expect(html).to include("--rose-edge: #e0699a; --rose-accent: #f2a3c4;")
    end

    it "shows SQL that pg_query can't parse as it was sent, escaped" do
      payload["rewrites"].first["sql"] = "SELECT FROM WHERE <b> $1"
      expect(queries).to include("<code>SELECT FROM WHERE &lt;b&gt; $1</code>")
    end

    # Task 20260926-42 counted the scenario groups a unique key left out;
    # task 20261012-4 removed the scenarios, so an older entry's count says
    # nothing now.
    it "says nothing of the test cases an older run's unique key left out" do
      payload["rewrites"].first["dropped"] = 2
      expect(section(render(payload), "queries")).not_to include("test case")
    end

    # Task 20261012-2: how many random small databases the fuzz search
    # compared a rewrite on, when none proved it wrong. Task 20261016-3: in
    # the user's words (2026-10-16), what the rewrite survived, counting
    # enumerate's databases too.
    describe "the generated data sets a rewrite survived" do
      def survived(trials, fate = "ranked")
        payload["rewrites"].first.merge!("trials" => trials, "fate" => fate)
        section(render(payload), "queries")
      end

      def line(text) = text[%r{<p class="fuzz">(.*?)</p>}, 1]

      let(:lead) { "trying to show it gives different results from the original query" }

      it "says how many mechanically generated data sets it survived" do
        expect(line(survived(41_200))).to eq("Vivid Cove survived 41,200 mechanically generated data sets #{lead}.")
        expect(line(survived(1))).to eq("Vivid Cove survived 1 mechanically generated data set #{lead}.")
      end

      it "names the rewrite by its number past the last name" do
        number = Quaack::Driver::RewriteNames::SIZE + 1
        payload["rewrites"].first["rewrite"] = "rewrite_#{number}"
        expect(line(survived(3))).to eq("Rewrite #{number} survived 3 mechanically generated data sets #{lead}.")
      end

      it "says nothing when fuzz compared none, disproved it, or the count isn't one" do
        [0, nil, -1, "2", 1.5].each { expect(survived(it)).not_to include('class="fuzz"') }
        expect(survived(5, "fuzz_disproved")).not_to include('class="fuzz"')
      end

      # Task 20261012-3.
      def enumerated(bound, fate = "ranked", trials: 40, worlds: 905)
        payload["rewrites"].first.merge!("worlds" => worlds, "bound" => bound)
        line(survived(trials, fate)).to_s
      end

      it "counts enumerate's data sets too, and says every data set up to its bound was among them" do
        expect(enumerated(2)).to eq("Vivid Cove survived 945 mechanically generated data sets #{lead}: 40 " \
                                    "random ones, then 905 enumerated in order of size, which covered every data " \
                                    "set of up to 2 rows over its value classes.")
        expect(enumerated(1, trials: 1, worlds: 1)).to eq("Vivid Cove survived 2 mechanically generated data sets " \
                                                          "#{lead}: 1 random one, then 1 enumerated in order of " \
                                                          "size, which covered every data set of up to 1 row over " \
                                                          "its value classes.")
      end

      it "counts enumerate's data sets with no bound when it finished none, or the bound isn't one" do
        [0, nil, 5, "2", -1].each do |bound|
          expect(enumerated(bound)).to eq("Vivid Cove survived 945 mechanically generated data sets #{lead}: 40 " \
                                          "random ones, then 905 enumerated in order of size."), bound.inspect
        end
      end

      it "says only fuzz's count when enumerate compared none, or its count isn't one" do
        [0, nil, -1, "9"].each do |worlds|
          expect(enumerated(2, worlds:)).to eq("Vivid Cove survived 40 mechanically generated data sets #{lead}.")
        end
      end

      it "says nothing when enumerate disproved it, or fuzz compared none" do
        expect(enumerated(2, "enumerate_disproved")).to eq("")
        expect(enumerated(2, trials: 0)).to eq("")
      end

      it "claims no bound when a later stage disproved the rewrite" do
        %w[rewrite_test_disproved counterexamples_disproved production_mismatch].each do |fate|
          expect(enumerated(2, fate)).to eq("Vivid Cove survived 945 mechanically generated data sets #{lead}: " \
                                            "40 random ones, then 905 enumerated in order of size.")
        end
      end

      it "claims the bound for a rewrite that passed every test but wasn't faster" do
        expect(enumerated(2, "not_better")).to end_with("which covered every data set of up to 2 rows over its " \
                                                        "value classes.")
      end

      # Task 20261012-28: the accountability table's wrong results are the
      # disproofs, so a new one there claims no bound either.
      it "claims no bound for a disproof fate the accountability table gains" do
        accountability = Quaack::Driver::Report::Accountability
        stub_const("#{accountability}::OUTCOMES",
                   accountability::OUTCOMES.merge("new_stage_disproved" => accountability::WRONG))
        expect(enumerated(2, "new_stage_disproved")).to end_with("905 enumerated in order of size.")
      end
    end

    # Task 20261016-4: why fuzz stopped, from its stop rule, so a reader sees
    # why rewrites got different counts.
    describe "why the random search stopped" do
      def stopped(stop, trials: 1790, fate: "ranked")
        payload["rewrites"].first.merge!("trials" => trials, "fate" => fate, "fuzz_stop" => stop)
        CGI.unescapeHTML(section(render(payload), "queries")[%r{<p class="fuzz">(.*?)</p>}, 1].to_s)
      end

      def stop(reason, seconds, quiet) = { "reason" => reason, "seconds" => seconds, "quiet" => quiet }

      let(:survived) do
        "Vivid Cove survived 1,790 mechanically generated data sets trying to show it gives different results " \
          "from the original query."
      end

      it "says it ran dry, after how long, and how long it had found no new plan behaviour" do
        expect(stopped(stop("dry", 41, 20)))
          .to eq("#{survived} Its random search stopped after 41 s: no new plan behaviour for the last 20 s.")
        expect(stopped(stop("dry", 1, 1))).to end_with("stopped after 1 s: no new plan behaviour for the last 1 s.")
      end

      it "says it stopped at its minimum, with how long it had found nothing new" do
        expect(stopped(stop("floor", 30, 26)))
          .to eq("#{survived} Its random search stopped after its minimum of 30 s: no new plan behaviour for the " \
                 "last 26 s.")
      end

      it "says it stopped at its limit, and when it last found new plan behaviour" do
        expect(stopped(stop("cap", 60, 8)))
          .to eq("#{survived} Its random search stopped at its 60 s limit, having last found new plan behaviour " \
                 "8 s before.")
      end

      it "says the rewrite's time budget ran out" do
        expect(stopped(stop("deadline", 13, nil)))
          .to eq("#{survived} Its random search stopped after 13 s, when the rewrite's 5-minute time budget ran out.")
      end

      it "says the differences it found didn't hold up with every constraint enforced" do
        expect(stopped(stop("unlifted", 22, nil)))
          .to eq("#{survived} Its random search stopped after 22 s, once several differences it found didn't " \
                 "hold up with every constraint enforced.")
      end

      it "says a count of trials set for testing QUAACK stopped it, not time, when no times were sent" do
        expect(stopped(stop("trials", nil, nil)))
          .to eq("#{survived} Its random search stopped after a number of trials set for testing QUAACK, not " \
                 "by time.")
      end

      # Task 20261016-4's fix round: a stop no search could make says nothing.
      it "says nothing of a stop whose times its reason can't have" do
        [stop("dry", nil, nil), stop("floor", 30, nil), stop("deadline", nil, nil), stop("unlifted", 22, 5),
         stop("trials", 41, 20)].each { expect(stopped(it)).to eq(survived), it.inspect }
      end

      it "says nothing of a stop that isn't sent, or when it says nothing of the data sets" do
        expect(stopped(nil)).to eq(survived)
        expect(stopped(stop("secret", 41, 20))).to eq(survived)
        expect(stopped(stop("dry", 41, 42))).to eq(survived)
        expect(stopped(stop("dry", 41, 20), trials: 0)).to eq("")
        expect(stopped(stop("dry", 41, 20), fate: "fuzz_disproved")).to eq("")
      end
    end

    # Task 20261016-3: the list wasn't actionable, so the report says what the
    # rewrite survived instead. The untested conditions stay internal, for the
    # LLM's test data to aim at.
    describe "the conditions no test ever exercised" do
      it "lists none of them" do
        payload["rewrites"].first.merge!("untested_atoms" => ["a < $1", "t.b IS NULL"], "covered" => nil,
                                         "untested_unchanged" => nil)
        queries = section(render(payload), "queries")
        expect(queries).not_to include('class="untested"')
        expect(queries).not_to include("t.b IS NULL")
        expect(queries).not_to include("both true and false")
      end
    end

    describe "the warning, shown once while a section is open" do
      it "sits in the summary and again in the body, and the CSS hides the summary's copy when open" do
        payload["rewrites"].first["out_of_time"] = true
        out = render(payload)
        body = section(out, "queries")[%r{</summary>\s*<p class="warn body-warn">(.*?)</p>}m, 1]
        expect(body).to eq(section(out, "queries")[%r{<span class="warn">(.*?)</span>}m, 1])
        expect(out).to include("details[open] > summary .warn { display: none; }")
      end

      it "says the data caution once in an open body, and keeps it whole in the summary" do
        entry = payload["rewrites"].first
        entry["empirical"] = [{ "table" => "a", "column" => "x", "references_table" => "b", "id_column" => "id",
                                "type_column" => "kind" }]
        entry["out_of_time"] = true
        queries = section(render(payload), "queries")
        summary = queries[%r{<span class="warn">(.*?)</span>}m, 1]
        body = queries[%r{<h3>Rewrite Vivid Cove</h3>.*?</summary>(.*?)<pre class="sql">}m, 1]
        expect(summary).to include("relies on what your data holds today")
        expect(body.scan("your data holds today").size).to eq(1)
        expect(body).to include("something your data holds today but your schema")
        expect(body[%r{<p class="warn body-warn">(.*?)</p>}m, 1])
          .to start_with("Read it with care: its test on made-up data")
      end
    end

    describe "where a rewrite came from (rewrite-rules)" do
      def source(**fields)
        payload["rewrites"].first.merge!(fields.transform_keys(&:to_s))
        section(render(payload), "queries")[%r{<span class="source">.*?</span>}m]
      end

      it "says which of QUAACK's rules made a rule-made rewrite, linked to the rule's page" do
        expect(source).to eq(esc(%(<span class="source">Where it came from: transform rule ) \
                                 "#{link("key_in_self_join")}.</span>"))
      end

      it "names every rule of a chained rewrite, in order, each linked" do
        expect(source(rules: %w[or_to_union key_in_self_join]))
          .to include(esc("transform rules #{link("or_to_union")}, then " \
                          "#{link("key_in_self_join")}."))
      end

      it "links no name that isn't one of QUAACK's rules, and still names it" do
        expect(source(rules: %w[made_up_rule key_in_self_join]))
          .to include(esc("rules made_up_rule, then #{link("key_in_self_join")}."))
        expect(source(rules: ["implied_predicate_removal.md#x"])).to include("rule implied_predicate_removal.md#x.")
          .and(satisfy { !it.include?("<a ") })
      end

      it "names no rule, and leaves no dangling words, when the payload has none" do
        expect(source(rules: [])).to include("Where it came from: transform rules.</span>")
        expect(source(rules: nil)).to include("Where it came from: transform rules.</span>")
      end

      it "says when the LLM suggested it, or it's the operator's own" do
        expect(source(source: "llm", rules: nil))
          .to include("Where it came from: suggested by the LLM (its model wasn&#39;t recorded).")
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
                                        "names the type in the original query. QUAACK checked it on the real data.</p>"
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
        expect(fate("ranked")).to eq("It beat the original query and is ranked below.")
      end

      it "says a rewrite that plans as the original does was never tested" do
        expect(fate("same_plans")).to eq(esc("Postgres plans it exactly as it plans the original query, so it " \
                                             "can't run any differently. QUAACK didn't test it further."))
      end

      # Task 20261012-4: an entry stored before the search replaced
      # rewrite-test's scenarios may still name one; the report doesn't.
      it "says made-up data proved an older run's rewrite wrong, without naming its scenario" do
        expect(fate("rewrite_test_disproved", scenario: "s2", rule: "multiset"))
          .to eq(esc("It returned different results from the original query on made-up test data, so it's wrong."))
        expect(fate("rewrite_test_disproved", scenario: "s3", rule: "row_count")).not_to include("duplicate join")
      end

      it "says which round of LLM-written data proved a rewrite wrong" do
        expect(fate("counterexamples_disproved", round: 2, rule: "row_count"))
          .to eq(esc("It returned different results from the original query on test data the LLM wrote to break it " \
                     "(round 2), so it's wrong."))
      end

      it "leaves out a scenario or round the payload doesn't have, with no stray brackets" do
        expect(fate("rewrite_test_disproved"))
          .to eq(esc("It returned different results from the original query on made-up test data, so it's wrong."))
        expect(fate("counterexamples_disproved"))
          .to eq(esc("It returned different results from the original query on test data the LLM wrote to break it, " \
                     "so " \
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
          .to eq(esc("A test on made-up data ended without comparing results, because the order " \
                     "of the original query's rows can't be checked, so QUAACK dropped it. That says nothing about " \
                     "whether it's right."))
        expect(fate("counterexamples_failed", round: 1, rule: "statement_timeout"))
          .to include("(round 1) ended without comparing results, because a statement timed out, so")
        expect(fate("rewrite_test_failed", scenario: "s1", rule: "query_failed"))
          .to include("ended without comparing results, because a statement failed on the test database, so")
        expect(fate("rewrite_test_failed", rule: "original_failed"))
          .to eq(esc("A test on made-up data ended without comparing results, because the original query failed " \
                     "on the test data, so QUAACK dropped it. That says nothing about whether it's right."))
      end

      it "says a rewrite whose test ran past its budget was left out, not that it's wrong (20261010-53)" do
        expect(fate("rewrite_test_out_of_time"))
          .to eq(esc("QUAACK couldn't test it within 5 minutes, so it left it out and won't recommend it. That " \
                     "says nothing about whether it's right."))
      end

      # Task 20261012-2: the fuzz search's disproof, by its size per table
      # and its rule, never its rows.
      it "says a random small database proved a rewrite wrong, with its rows per table and the rule" do
        sizes = [["public", "orders", 2], ["public", "customers", 1]]
        expect(fate("fuzz_disproved", rule: "row_count", sizes:))
          .to eq(esc("It returned different results from the original query on a random small database built " \
                     "around its own values (2 rows in orders and 1 in customers; the row count differs), so it's " \
                     "wrong."))
        expect(fate("fuzz_disproved", rule: "multiset", sizes: [["sales", "orders", 1]]))
          .to include(esc("(1 row in sales.orders; the rows differ)"))
        expect(fate("fuzz_disproved", rule: "value", sizes: [["a", "x", 3], ["b", "y", 3], ["c", "z", 3]]))
          .to include("(3 rows in a.x, 3 in b.y, and 3 in c.z; a value differs)")
      end

      # Task 20261012-13: a size of 5 means 5 or more; a higher one isn't a size.
      it "says 5 rows in a table as 5 or more, and leaves out a higher count" do
        lead = "It returned different results from the original query on a random small database built around " \
               "its own values"
        expect(fate("fuzz_disproved", sizes: [["public", "orders", 5], ["public", "customers", 5]]))
          .to eq(esc("#{lead} (5 or more rows in orders and 5 or more in customers), so it's wrong."))
        expect(fate("fuzz_disproved", sizes: [["public", "orders", 4]]))
          .to eq(esc("#{lead} (4 rows in orders), so it's wrong."))
        [6, 37].each do |rows|
          expect(fate("fuzz_disproved", sizes: [["public", "orders", rows]])).to eq(esc("#{lead}, so it's wrong."))
        end
      end

      it "leaves out a fuzz disproof's sizes or rule the payload doesn't have, or that aren't sizes" do
        lead = "It returned different results from the original query on a random small database built around " \
               "its own values"
        expect(fate("fuzz_disproved")).to eq(esc("#{lead}, so it's wrong."))
        expect(fate("fuzz_disproved", rule: "row_count"))
          .to eq(esc("#{lead} (the row count differs), so it's wrong."))
        expect(fate("fuzz_disproved", sizes: [["public", "orders", 2]]))
          .to eq(esc("#{lead} (2 rows in orders), so it's wrong."))
        [[%w[public orders 2]], [["public", "orders", 0]], "orders", [["orders", 2]]].each do |sizes|
          expect(fate("fuzz_disproved", sizes:)).to eq(esc("#{lead}, so it's wrong."))
        end
      end

      # The user's decision (2026-10-12): the rewrite failing where the
      # original ran disproves it. The error's text never reaches here.
      it "says a random small database proved a rewrite wrong by making it fail where the original query ran" do
        expect(fate("fuzz_disproved", rule: "query_failed", sizes: [["public", "orders", 1]]))
          .to eq(esc("It failed on a random small database built around its own values (1 row in orders), where " \
                     "the original query ran, so it's wrong."))
        expect(fate("fuzz_disproved", rule: "query_failed"))
          .to eq(esc("It failed on a random small database built around its own values, where the original query " \
                     "ran, so it's wrong."))
      end

      # Task 20261012-3: enumerate's disproof, worded like fuzz's.
      it "says a small database QUAACK enumerated proved a rewrite wrong, with its rows per table and the rule" do
        expect(fate("enumerate_disproved", rule: "value", sizes: [["public", "topics", 2]]))
          .to eq(esc("It returned different results from the original query on a small database QUAACK enumerated " \
                     "from its own values (2 rows in topics; a value differs), so it's wrong."))
        expect(fate("enumerate_disproved", rule: "query_failed", sizes: [["public", "orders", 1]]))
          .to eq(esc("It failed on a small database QUAACK enumerated from its own values (1 row in orders), where " \
                     "the original query ran, so it's wrong."))
      end

      it "says a rewrite was never tested when rewrite-test couldn't build test data, and why, by rule" do
        expect(fate("rewrite_test_untested", rule: "complex_check"))
          .to eq(esc("QUAACK couldn't make up test data for the original query, because a CHECK constraint on its " \
                     "tables " \
                     "is too complex for QUAACK to satisfy, so it never tested this rewrite and won't recommend " \
                     "it. That says nothing about whether it's right."))
        {
          "fk_cycle" => "its tables' foreign keys form a cycle QUAACK can't load",
          "unsupported_type" => "a column has a type QUAACK can't fill",
          "expression_unique_index" => "a unique index on an expression calls a function QUAACK can't trust",
          "unsatisfiable_check" => "no value QUAACK tried passes a CHECK constraint on its tables",
          "domain_check" => "a column's domain rejects every value QUAACK tried",
          "exclusion_constraint" => "an exclusion constraint on its tables has no = column"
        }.each do |rule, words|
          expect(fate("rewrite_test_untested",
                      rule:)).to include(esc("for the original query, because #{words}, so it " \
                                             "never"))
        end
        expect(fate("rewrite_test_untested"))
          .to eq(esc("QUAACK couldn't make up test data for the original query, so it never tested this rewrite and " \
                     "won't " \
                     "recommend it. That says nothing about whether it's right."))
      end

      it "names the tables of an fk_cycle refusal, in the order their foreign keys point" do
        expect(fate("rewrite_test_untested", rule: "fk_cycle",
                                             cycle: %w[public.accounts public.courses public.accounts]))
          .to eq(esc("QUAACK couldn't make up test data for the original query, because its tables' foreign keys " \
                     "form a " \
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
          .to eq(esc("It passed the tests on made-up data, but returned different results from the original query " \
                     "on the " \
                     "real data, so it's wrong."))
        expect(fate("production_timed_out")).to include("but timed out when QUAACK compared its results with")
        expect(fate("production_not_compared", rule: "unsupported_order"))
          .to include(esc("but QUAACK couldn't compare its results with the original query's on the real data, " \
                          "because " \
                          "the order of the original query's rows can't be checked, so"))
        expect(fate("production_not_compared")).to include(esc("on the real data, so QUAACK dropped it."))
      end

      it "says how a rewrite that passed every test lost" do
        expect(fate("not_better")).to eq("It passed every correctness test, but when measured against real data " \
                                         "performed too poorly to be ranked.")
        expect(fate("footprint_tie")).to include("tied with a candidate whose new indices take no more disk space")
        expect(fate("below_top_three")).to include("three others of its kind did better")
        expect(fate("measurement_timed_out")).to include("every measurement run of it timed out")
      end

      it "says the same for a not_better rewrite whatever its verdicts show" do
        payload["labels"] << { "label" => "rewrite_2:none", "search" => "rewrite_2", "indexes" => [],
                               "timed_out" => false, "measurements" => {},
                               "verdicts" => { "slow" => "no_worse", "typical" => "no_worse" } }
        payload["excluded"]["rewrite_2:none"] = "not_better"
        sentence = "It passed every correctness test, but when measured against real data performed too poorly " \
                   "to be ranked."
        expect(fate("not_better")).to eq(sentence)
        payload["labels"].last["verdicts"] = { "slow" => "better", "typical" => "worse" }
        expect(fate("not_better")).to eq(sentence)
      end

      it "says how far an unfinished rewrite got" do
        expect(fate("unfinished")).to eq("QUAACK kept it, but the run ended before testing it.")
        expect(fate("unfinished",
                    after: "rewrite-test")).to include("passed the tests on made-up data, and the run ended")
        expect(fate("unfinished", after: "counterexamples")).to include("passed every correctness test, and the run " \
                                                                        "ended before")
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
    let(:opening) { '<details class="fold rose" id="not-ranked-section">' }

    it "opens by naming the three classes of candidate, how many it keeps, and the rule for being ranked" do
      expect(ranking).to include(
        "<p>QUAACK ranks 3 classes of candidates: the original query with different indices available, a rewrite " \
        "of the original query, and a rewrite of the original query with different indices available. The three " \
        "best candidates are kept for each class. To be considered for ranking, a candidate must read more than 5% " \
        "fewer blocks than the original query using the values provided, and no more than 5% <em>more</em> blocks " \
        "on any other set of values.</p>"
      )
    end

    it "ranks the candidates within each kind, each described in words" do
      expect(ranking.scan(%r{<tr class="rank[^"]*"><td class="num">(\d)</td><td>(.*?)</td>}))
        .to eq([["1", "Rewrite Vivid Cove with no new indices"],
                ["1", "The original query with a new index on #{sq("public.t (created_at)")}"]])
    end

    it "groups the ranked candidates by kind, ranking within each, with the payload's kind deciding the group" do
      payload["top"] = [
        { "label" => "original:top:1", "kind" => "original_new_indexes", "slow_blocks" => 10, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:none", "kind" => "rewrite_same_indexes", "slow_blocks" => 20, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:1", "kind" => "rewrite_new_indexes", "slow_blocks" => 30, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:2", "kind" => "rewrite_new_indexes", "slow_blocks" => 40, "total_blocks_sum" => 1,
          "footprint" => 0 }
      ]
      expect(ranking.scan(/<tr class="(?:kind|rank)[^"]*">(?:<th[^>]*>|<td class="num">)([^<]*)/))
        .to eq([["A rewrite of the original query, with new indices"], ["1"], ["2"],
                ["A rewrite of the original query, with no new indices"], ["1"],
                ["The original query, with new indices"], ["1"]])
      expect(ranking.scan(/<article class="candidate"><h3>(\d)\./).flatten).to eq(%w[1 2 1 1])
    end

    it "wraps each kind's heading and numbered entries below the table in one block, striped by kind" do
      payload["top"] = [
        { "label" => "original:top:1", "kind" => "original_new_indexes", "slow_blocks" => 10, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:none", "kind" => "rewrite_same_indexes", "slow_blocks" => 20, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:1", "kind" => "rewrite_new_indexes", "slow_blocks" => 30, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:2", "kind" => "rewrite_new_indexes", "slow_blocks" => 40, "total_blocks_sum" => 1,
          "footprint" => 0 }
      ]
      groups = ranking.scan(%r{<div class="kind-group (stripe-\w+)">\n(.*?)\n</div>}m)
      expect(groups.map(&:first))
        .to eq(%w[stripe-rewrite_new_indexes stripe-rewrite_same_indexes stripe-original_new_indexes])
      expect(groups.map { |_, body| body.scan(%r{<h3 class="kind">[^<]*</h3>}).size }).to eq([1, 1, 1])
      expect(groups.map { |_, body| body.start_with?('<h3 class="kind">') }).to eq([true] * 3)
      expect(groups.map { |_, body| body.scan(/<article class="candidate"><h3>(\d)\./).flatten })
        .to eq([%w[1 2], %w[1], %w[1]])
      style = html[%r{<style>(.*?)</style>}m, 1]
      stripes = style.scan(/\.stripe-(\w+) \{ --stripe: (var\(--st-[a-z]+\)); \}/)
      expect(stripes.map(&:first)).to eq(%w[rewrite_new_indexes rewrite_same_indexes original_new_indexes])
      expect(stripes.map(&:last)).to eq(%w[var(--st-teal) var(--st-violet) var(--st-brown)])
      group = style[/div\.kind-group \{[^}]*\}/]
      expect(group).to include("border-left: 5px solid var(--stripe)")
      dark = style[/prefers-color-scheme: dark\).*?\n  \}\n/m]
      expect(dark).to include("--st-teal:", "--st-violet:", "--st-brown:")
    end

    it "stripes each of the table's rows on its left edge in its kind's block's color, and leaves the baseline plain" do
      # rewrite_1 is ranked in two kinds: each of its rows takes the stripe of the kind it sits under.
      payload["top"] = [
        { "label" => "original:top:1", "kind" => "original_new_indexes", "slow_blocks" => 10, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:none", "kind" => "rewrite_same_indexes", "slow_blocks" => 20, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:1", "kind" => "rewrite_new_indexes", "slow_blocks" => 30, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:2", "kind" => "rewrite_new_indexes", "slow_blocks" => 40, "total_blocks_sum" => 1,
          "footprint" => 0 }
      ]
      table = ranking[%r{<table>.*?</table>}m]
      rows = table.scan(/<tr class="([^"]*)">(?:<th[^>]*>|<td class="num">)([^<]*)/)
      expect(rows).to eq([["baseline", ""],
                          ["kind stripe-rewrite_new_indexes", "A rewrite of the original query, with new indices"],
                          ["rank stripe-rewrite_new_indexes", "1"], ["rank stripe-rewrite_new_indexes", "2"],
                          ["kind stripe-rewrite_same_indexes", "A rewrite of the original query, with no new indices"],
                          ["rank stripe-rewrite_same_indexes", "1"],
                          ["kind stripe-original_new_indexes", "The original query, with new indices"],
                          ["rank stripe-original_new_indexes", "1"]])
      # Each row's stripe class names the same kind as the block below that holds its entry.
      blocks = ranking.scan(/<div class="kind-group (stripe-\w+)">/).flatten
      expect(rows.map { it.first[/stripe-\w+/] }.compact.uniq).to eq(blocks)
      style = html[%r{<style>(.*?)</style>}m, 1]
      row_rule = style[/^  tr\.kind > :first-child, tr\.rank > :first-child \{[^}]*\}/]
      expect(row_rule).to include("border-left: 5px solid var(--stripe)")
      expect(row_rule).not_to match(/background/)
      # Task 20261017-10 item 1: no other rule on the kind or rank rows tints them or reuses the stripe.
      row_rules = style.scan(/^  [^{}\n]*\btr\.(?:kind|rank)\b[^{}\n]*\{[^}]*\}/)
      expect(row_rules).to include(row_rule)
      (row_rules - [row_rule]).each { expect(it).not_to match(/background|--stripe/) }
    end

    # Task 20261017-10 item 2: with collapsed borders, the baseline row's left edge lines up with the stripes.
    it "gives the baseline row's first cell a transparent 5px left border, as wide as the stripes" do
      style = html[%r{<style>(.*?)</style>}m, 1]
      expect(style).to match(/^  tr\.baseline > :first-child \{ border-left: 5px solid transparent; \}/)
    end

    it "gives each kind's block no shading of its own, so it shows the page background in light and dark mode" do
      style = html[%r{<style>(.*?)</style>}m, 1]
      kind_rules = style.scan(/^  [^{}\n]*(?:kind-group|stripe-)[^{}\n]*\{[^}]*\}/)
      expect(kind_rules.size).to eq(5)
      kind_rules.each { expect(it).not_to match(/background|--stripe-bg/) }
      light = style[/^  :root \{.*?^  \}/m]
      dark = style[/prefers-color-scheme: dark\).*?\n  \}\n/m]
      [light, dark].each { expect(it).not_to match(/--sb-|--stripe-bg/) }
    end

    it "puts \"Measured, and not ranked\" last, after every kind's block" do
      payload["top"] = [
        { "label" => "original:top:1", "kind" => "original_new_indexes", "slow_blocks" => 10, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:none", "kind" => "rewrite_same_indexes", "slow_blocks" => 20, "total_blocks_sum" => 1,
          "footprint" => 0 },
        { "label" => "rewrite_1:top:1", "kind" => "rewrite_new_indexes", "slow_blocks" => 30, "total_blocks_sum" => 1,
          "footprint" => 0 }
      ]
      headings = ranking.scan(%r{<h3(?: class="kind")?>([^<]*)</h3>}).flatten.grep_v(/\A\d/)
      expect(headings).to eq(["A rewrite of the original query, with new indices",
                              "A rewrite of the original query, with no new indices",
                              "The original query, with new indices", "Measured, and not ranked"])
      expect(ranking).to match(%r{</div>\n<h3>Measured, and not ranked</h3>\n#{opening}.*?</details>\n</section>\z}m)
    end

    it "shows each candidate's blocks and index footprint, right-aligned, with separators and a fitting unit" do
      payload["top"][1].merge!("slow_blocks" => 12_345, "total_blocks_sum" => 1_234_567, "footprint" => 5_000_000)
      expect(ranking).to include('<td class="num">12,345</td><td class="num">1,234,567</td>' \
                                 '<td class="num">4.8 MB</td></tr>')
      expect(ranking).to include('<td class="num">300</td><td class="num">400</td><td class="num">0 kB</td></tr>')
    end

    describe "the original query, for comparison" do
      def baseline(html = ranking) = html[%r{<tr class="baseline">.*?</tr>}m]

      it "is a row above the ranked ones, with no rank, marked as the baseline, with its own blocks" do
        expect(ranking.scan(/<tr class="(\w+)[ "]/).flatten).to eq(%w[baseline kind rank kind rank])
        expect(baseline).to eq('<tr class="baseline"><td class="num"></td><td>The original query (the baseline, ' \
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

      it "says timed out where the original query timed out" do
        payload["original_measurements"]["slow"] = { "timed_out" => true }
        payload["infinite_sets"] = ["slow"]
        expect(baseline).to include('<td class="num">timed out</td><td class="num">timed out</td>')
      end

      it "says timed out in the sum, but not for the slow values, where the original query timed out on another set" do
        payload["original_measurements"]["worst_case"] = { "timed_out" => true }
        payload["infinite_sets"] = ["worst_case"]
        payload["labels"][0]["measurements"]["worst_case"] = m(5, 0)
        expect(baseline).to include('<td class="num">1,000</td><td class="num">timed out</td>')
      end
    end

    it "describes a candidate with several indices, and one whose index definition is missing" do
      payload["labels"][0]["indexes"] = %w[quaack_a quaack_b]
      expect(ranking)
        .to include("<td>The original query with new indices on #{sq("public.t (created_at)")} and " \
                    "#{sq("public.t (a, b)")}</td>")
      payload["indexes"]["quaack_a"]["ddl"] = nil
      payload["labels"][0]["indexes"] = %w[quaack_a]
      expect(section(render(payload), "ranking"))
        .to include("<td>The original query with a new index QUAACK couldn&#39;t describe (#{sq("quaack_a")})</td>")
    end

    it "sets apart the whole definition of an index it can't take apart" do
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE UNIQUE INDEX ON public.t (created_at)"
      expect(ranking).to include("The original query with a new index on " \
                                 "#{sq("CREATE UNIQUE INDEX ON public.t (created_at)")}")
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE UNIQUE INDEX ON public.t USING btree (created_at)"
      expect(section(render(payload), "ranking"))
        .to include("The original query with a new index on " \
                    "#{sq("CREATE UNIQUE INDEX ON public.t USING btree (created_at)")}")
    end

    it "puts an index's method inside its SQL when it isn't a btree, and keeps its predicate" do
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.t USING brin (created_at) WHERE a < ?"
      expect(ranking)
        .to include("The original query with a new index on #{sq("public.t USING brin (created_at) WHERE a &lt; ?")}")
      expect(ranking).not_to include("(brin)")
    end

    # Task 20261003-4: a quoted table name can hold a space, or even USING.
    it "takes apart an index on a quoted table name with a space in it" do
      payload["indexes"]["quaack_a"]["ddl"] = 'CREATE INDEX ON public."my USING t" USING btree (created_at)'
      expect(ranking).to include("The original query with a new index on " \
                                 "#{sq("public.&quot;my USING t&quot; (created_at)")}")
      payload["indexes"]["quaack_a"]["ddl"] = 'CREATE INDEX ON "s x"."my t" USING gin (b) WHERE a < ?'
      expect(section(render(payload), "ranking"))
        .to include("The original query with a new index on " \
                    "#{sq("&quot;s x&quot;.&quot;my t&quot; USING gin (b) WHERE a &lt; ?")}")
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON café.t USING btree (créé)"
      expect(section(render(payload), "ranking"))
        .to include("The original query with a new index on #{sq("café.t (créé)")}")
      payload["indexes"]["quaack_a"]["ddl"] = "CREATE INDEX ON public.data USING btree (a)"
      expect(section(render(payload), "ranking"))
        .to include("The original query with a new index on #{sq("public.data (a)")}")
    end

    describe "what was measured and not ranked" do
      let(:unranked) { ranking[%r{<table id="not-ranked">.*?</table>}m] }

      def rows(html = unranked) = html.to_s.scan(%r{<tr>(.*?)</tr>}m).flatten.drop(1)

      # The source of rewrite 1 with quaack_b, which the query's plan inspired.
      def rule = "Made by transform rule key_in_self_join; indices: from the query&#39;s plan"

      # A row of the table: what it was, who proposed it, and why it wasn't ranked.
      def row(what, why, who: rule)
        "<tr><td>#{what}</td>#{who ? "<td>#{who}</td>" : '<td class="missing">not recorded</td>'}<td>#{why}</td></tr>"
      end

      it "is a table behind a collapsed section, with a row each for what it was, who proposed it, and why" do
        collapsed = ranking[%r{#{opening}\s*<summary>(.*?)</summary>(.*?)</details>}m, 0]
        expect(collapsed).to include("<summary>Show the 1 thing QUAACK tried that didn't pan out</summary>")
        expect(collapsed).to include(unranked)
        expect(ranking).not_to match(/<details[^>]*\bopen\b/)
        expect(unranked).to include(%(<thead><tr><th scope="col">What it was</th><th scope="col">Who proposed it</th>) +
                                    %(<th scope="col">Why it didn't make the cut</th></tr></thead>))
        expect(rows).to eq(
          ["<td>Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}</td>" \
           "<td>Made by transform rule " \
           "key_in_self_join; indices: from the query&#39;s plan</td><td>Read 7,777 blocks on the slow values, " \
           "against 1,000 for the original query, which isn&#39;t more than 5% fewer.</td>"]
        )
      end

      def whos = rows.map { it.scan(%r{<td[^>]*>(.*?)</td>}).flatten[1] }

      # Task 20261004-89 item 2.
      it "names the rewrite's source, then, after 'indices:', the sources of the new indices it ran with" do
        payload["rewrites"].first["source"] = "llm"
        payload["excluded"]["original:top:1"] = "footprint_tie"
        payload["top"].pop
        payload["excluded"]["rewrite_1:none"] = "below_top_three"
        expect(whos).to eq(["Suggested by the LLM; indices: from the query&#39;s plan",
                            "Indices: from the query&#39;s text, from the LLM", "Suggested by the LLM"])
        expect(section(render(payload), "ranking")).to include(
          "Who proposed it starts with who proposed the rewrite, if there is one, and goes on, after " \
          "\"indices:\", to where the new indices it ran with came from: \"from the query's text\", " \
          "\"from the query's plan\", or \"from the LLM\". An index that more than " \
          "one of them proposed lists each. A pairing QUAACK tried with indices another candidate's search " \
          "proposed says \"from another candidate\", then where that candidate had them from. " \
          "It says not recorded where this run didn't record who proposed " \
          "the indices (\"and others not recorded\" when it recorded some of them), and for a rewrite " \
          "whose source this run didn't record, or that's missing from what QUAACK's jump server sent.</p>"
        )
      end

      # Task 20261011-14 item 2: the report says where an index idea came from in the burndown's words.
      it "never says generator one or generator two, anywhere in the report, and names the burndown's words instead" do
        payload["labels"][2]["indexes"] = %w[quaack_b quaack_a]
        out = render(payload)
        expect(out).not_to match(/generator[ _-]?(one|two)/i)
        expect(whos).to eq(["Made by transform rule key_in_self_join; indices: from the query&#39;s text, " \
                            "from the query&#39;s plan, from the LLM"])
        expect(section(out, "accountability")).to include(">From the query&#39;s text<", ">From the query&#39;s plan<")
      end

      it "lists a source once, in the protocol's order, when several of a label's indices share it" do
        payload["labels"][2]["indexes"] = %w[quaack_b quaack_a]
        expect(whos).to eq(["Made by transform rule key_in_self_join; indices: from the query&#39;s text, " \
                            "from the query&#39;s plan, from the LLM"])
      end

      it "says not recorded for the indices of a run that recorded no sources, and never says none" do
        payload["excluded"]["original:top:1"] = "footprint_tie"
        payload["top"].pop
        payload["indexes"].each_value { it.delete("sources") }
        expect(whos).to eq(["Made by transform rule key_in_self_join; indices: not recorded", "not recorded"])
        payload["indexes"].each_value { it["sources"] = [] }
        expect(whos).to eq(["Made by transform rule key_in_self_join; indices: not recorded", "not recorded"])
      end

      # Task 20261010-10. `html` is memoized, so each case renders afresh.
      it "says others are not recorded when only some of a label's indices have recorded sources" do
        payload["excluded"]["original:top:1"] = "footprint_tie"
        payload["top"].pop
        payload["labels"][2]["indexes"] = %w[quaack_a quaack_b]
        fresh = lambda do |sources|
          entry = payload["indexes"]["quaack_a"]
          sources ? entry["sources"] = sources : entry.delete("sources")
          rows(section(render(payload), "ranking")[%r{<table id="not-ranked">.*?</table>}m])
            .map { it.scan(%r{<td[^>]*>(.*?)</td>}).flatten[1] }
        end
        rule = "Made by transform rule key_in_self_join; indices: from the query&#39;s plan"
        expect(fresh.call(nil)).to eq(["#{rule} and others not recorded", "not recorded"])
        expect(fresh.call([])).to eq(["#{rule} and others not recorded", "not recorded"])
        expect(fresh.call(%w[llm])).to eq(["#{rule}, from the LLM", "Indices: from the LLM"])
      end

      # Task 20261017-2: a shared pairing ran with indices another candidate's search ranked.
      it "says a shared pairing's indices came from another candidate, then where that one had them from" do
        payload["labels"][2]["label"] = "rewrite_1:shared:1"
        payload["excluded"] = { "rewrite_1:shared:1" => "not_better" }
        expect(whos).to eq(["Made by transform rule key_in_self_join; indices: from another candidate, " \
                            "which had them from the query&#39;s plan"])
        payload["indexes"].each_value { it.delete("sources") }
        expect(rows(section(render(payload), "ranking")[%r{<table id="not-ranked">.*?</table>}m])
          .map { it.scan(%r{<td[^>]*>(.*?)</td>}).flatten[1] })
          .to eq(["Made by transform rule key_in_self_join; indices: from another candidate"])
        expect(section(render(payload), "ranking")).to include(
          "A pairing QUAACK tried with indices another candidate's search proposed says \"from another " \
          "candidate\", then where that candidate had them from."
        )
      end

      it "shows only the rewrite's source for a label with no new indices" do
        payload["labels"][2]["indexes"] = []
        expect(whos).to eq(["Made by transform rule key_in_self_join"])
      end

      it "counts the things tried in its summary" do
        payload["excluded"] = { "rewrite_1:top:1" => "not_better", "rewrite_1:none" => "below_top_three" }
        payload["top"] = [payload["top"].first.merge("label" => "original:top:1")]
        expect(section(render(payload), "ranking"))
          .to include("<summary>Show the 2 things QUAACK tried that didn't pan out</summary>")
      end

      it "says in words, with the numbers, that a candidate wasn't enough better on the slow values" do
        expect(unranked).to include(
          row("Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}",
              "Read 7,777 blocks on the slow values, against 1,000 for the original query, which isn&#39;t more " \
              "than 5% fewer.")
        )
      end

      it "says which other values a candidate was worse on, when it was better on the slow ones" do
        payload["labels"][2].merge!("measurements" => { "slow" => m(500, 1), "typical" => m(900, 1) },
                                    "verdicts" => { "slow" => "better", "typical" => "worse" })
        expect(unranked).to include(
          row("Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}",
              "Read fewer blocks on the slow values (500, against 1,000), but read 900 on the typical values, " \
              "against 200 for the original query, which is more than 5% more.")
        )
      end

      it "says a candidate timed out on the other values, or was worse where the original query has no number" do
        payload["labels"][2].merge!("measurements" => { "slow" => m(500, 1), "typical" => { "timed_out" => true } },
                                    "verdicts" => { "slow" => "better", "typical" => "worse" })
        expect(unranked).to include("Read fewer blocks on the slow values (500, against 1,000), but timed out on " \
                                    "the typical values.</td></tr>")
        payload["labels"][2]["measurements"]["typical"] = m(900, 1)
        payload["original_measurements"]["typical"] = { "timed_out" => true }
        expect(section(render(payload), "ranking")).to include("Read fewer blocks on the slow values (500, against " \
                                                               "1,000), but was worse on the typical values.</td></tr>")
      end

      it "gives no numbers for a candidate that wasn't better where the original query timed out on the slow values" do
        payload["original_measurements"]["slow"] = { "timed_out" => true }
        expect(unranked).to include(row("Rewrite Vivid Cove with a new index on #{sq("public.t (a, b)")}",
                                        "Was no better than the original query."))
      end

      it "says a candidate lost a tie on index size, fell outside the top three, or was dropped on real data" do
        payload["excluded"] = { "rewrite_1:top:1" => "footprint_tie" }
        expect(unranked).to include("(a, b)</code></td><td>#{rule}</td><td>Beat the original query, but tied with a " \
                                    "candidate whose new indices take no more disk space.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "below_top_three" }
        expect(section(render(payload), "ranking")).to include("<td>Beat the original query, but three others of its " \
                                                               "kind did better.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "result_mismatch" }
        expect(section(render(payload), "ranking"))
          .to include("<td>Was dropped when QUAACK compared the rewrite&#39;s results with the original query&#39;s " \
                      "on " \
                      "the real data. See rewrite Vivid Cove under the queries.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "result_timed_out" }
        expect(section(render(payload), "ranking"))
          .to include("<td>Timed out when QUAACK compared the rewrite&#39;s results with the original query&#39;s on " \
                      "the real data. See rewrite Vivid Cove under the queries.</td></tr>")
        payload["excluded"] = { "rewrite_1:top:1" => "result_not_compared" }
        expect(section(render(payload), "ranking"))
          .to include("<td>Was dropped because QUAACK couldn&#39;t compare the rewrite&#39;s results with the " \
                      "original query&#39;s on the real data. See rewrite Vivid Cove under the queries.</td></tr>")
      end

      it "says a candidate's measurement timed out" do
        payload["labels"] << { "label" => "rewrite_1:top:2", "search" => "rewrite_1", "indexes" => ["quaack_a"],
                               "timed_out" => true, "measurements" => nil, "verdicts" => nil }
        expect(unranked).to include(row("Rewrite Vivid Cove with a new index on #{sq("public.t (created_at)")}",
                                        "Timed out while QUAACK measured it.",
                                        who: "#{rule[/\A.*?(?=;)/]}; indices: from the query&#39;s text, from the LLM"))
      end

      it "lists a label once, by why it was left out, when one of its sets also timed out" do
        payload["labels"][2]["timed_out"] = true
        expect(rows.size).to eq(1)
        expect(unranked).not_to include("imed out while")
      end

      it "leaves out a ranked candidate, even one of whose sets timed out" do
        payload["labels"][0]["timed_out"] = true
        expect(rows.size).to eq(1)
        expect(unranked).not_to include("imed out while")
      end

      it "gives no numbers it doesn't have" do
        payload["labels"].delete_at(2)
        expect(unranked)
          .to include(row("Rewrite Vivid Cove with new indices", "Was no better than the original query.",
                          who: "Made by transform rule key_in_self_join"))
      end

      it "is left out when everything measured is ranked" do
        payload["excluded"] = {}
        expect(ranking).not_to include("not-ranked")
      end
    end

    it "says there's no ranking when nothing beat the original, and still says how each candidate measured" do
      ranking = section(render(negative_payload), "ranking")
      expect(ranking).to include(
        "<p>Nothing beat the original query, so there is no ranking. To be considered for ranking, a candidate must " \
        "read more than 5% fewer blocks than the original query using the values provided, and no more than 5% " \
        "<em>more</em> blocks on any other set of values.</p>"
      )
      expect(ranking.sub(%r{#{opening}.*?</details>}m, "")).not_to include("<tr")
      expect(ranking).to include("<tr><td>The original query with a new index on #{sq("public.t (created_at)")}</td>" \
                                 "<td>Indices: from the query&#39;s text, from the LLM</td><td>Read 990 blocks on " \
                                 "the slow values, against 1,000 for the original query, which isn&#39;t more than " \
                                 "5% fewer.</td></tr>")
    end

    describe "each ranked candidate" do
      def candidate(rank) = ranking.scan(%r{<article class="candidate">.*?</article>}m)[rank - 1]

      it "has its own block, in rank order, and no unranked candidate has one" do
        expect(ranking.scan(%r{<article class="candidate"><h3>(.*?)</h3>}))
          .to eq([['1. <a href="#rewrite-1">Rewrite Vivid Cove</a>'], ["1. With new indices:"]])
        expect(ranking.scan("<article").size).to eq(2)
      end

      it "names a rewrite with no new indices, linked to its SQL, and goes straight to its table" do
        expect(candidate(1)).to start_with(
          %(<article class="candidate"><h3>1. <a href="#rewrite-1">Rewrite Vivid Cove</a></h3>\n<table>)
        )
      end

      it "lists the original's new indices under its heading, then its table" do
        expect(candidate(2)).to start_with(
          %(<article class="candidate"><h3>1. With new indices:</h3>\n) \
          "<ul><li>#{sq("CREATE INDEX ON public.t USING btree (created_at)")}</li></ul>\n<table>"
        )
      end

      it "names a rewrite the payload doesn't hold, without a link" do
        payload["rewrites"] = []
        expect(candidate(1)).to start_with(%(<article class="candidate"><h3>1. Rewrite Vivid Cove</h3>\n<table>))
      end

      it "says which new indices weren't recorded when the payload has no entry for the label" do
        payload["labels"].shift
        expect(candidate(2))
          .to start_with(%(<article class="candidate"><h3>1. With new indices: not recorded</h3>\n<table>))
      end

      describe "a rewrite with new indices" do
        before do
          payload["top"].unshift({ "label" => "rewrite_1:top:1", "slow_blocks" => 250, "total_blocks_sum" => 350,
                                   "footprint" => 24_576 })
          payload["excluded"] = {}
          payload["labels"][2].merge!("indexes" => %w[quaack_a quaack_b],
                                      "measurements" => { "slow" => m(250, 1), "typical" => m(100, 100) },
                                      "verdicts" => { "slow" => "better", "typical" => "no_worse" })
        end

        it "names the rewrite, linked to its SQL, then lists its new indices, then its table" do
          expect(candidate(1)).to start_with(
            %(<article class="candidate"><h3>1. <a href="#rewrite-1">Rewrite Vivid Cove</a>, with new indices:</h3>\n) \
            "<ul><li>#{sq("CREATE INDEX ON public.t USING btree (created_at)")}</li>" \
            "<li>#{sq("CREATE INDEX ON public.t USING btree (a, b)")}</li></ul>\n<table>"
          )
        end

        it "gives each index's definition once, and doesn't repeat the rewrite's name" do
          expect(candidate(1).scan("public.t USING btree (created_at)").size).to eq(1)
          expect(candidate(1).scan("public.t USING btree (a, b)").size).to eq(1)
          expect(candidate(1)).not_to include("public.t (created_at)", "public.t (a, b)")
          expect(candidate(1).scan("Vivid Cove").size).to eq(1)
          expect(candidate(1)).not_to include("Its SQL is under", "Its new indices")
        end
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

      describe "against the original query" do
        def against(ours, theirs, verdict: "no_worse")
          payload["labels"][0].merge!("measurements" => { "slow" => m(400, 300), "typical" => ours },
                                      "verdicts" => { "slow" => "better", "typical" => verdict })
          payload["original_measurements"]["typical"] = theirs
          typical(section(render(payload), "ranking").scan(%r{<article class="candidate">.*?</article>}m)[1])
        end

        # A candidate's typical row's against-original-query cell.
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

        it "counts the blocks when the original query read none, since there's no percentage of zero" do
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

      it "gives each of the original's new indices once, and no rewrite a link or index it didn't run with" do
        expect(candidate(2).scan("public.t USING btree (created_at)").size).to eq(1)
        expect(candidate(2)).not_to include("public.t (created_at)", "Its new indices", "<a ")
        expect(candidate(1)).not_to include("CREATE INDEX", "Its SQL is under")
        expect(candidate(1).scan("Vivid Cove").size).to eq(1)
      end
    end
  end

  describe "why the winner reads fewer blocks" do
    let(:explanation) { section(html, "explanation") }

    # A plan node as the payload sends it.
    def pnode(type, depth, **shape)
      shape = { relation: nil, index: nil, est: 10, actual: 10, selectivity: nil, hit: 4, read: 3, time: nil,
                loops: 1 }.merge(shape)
      { "node" => type, "relation" => shape[:relation], "index" => shape[:index], "est_rows" => shape[:est],
        "actual_rows" => shape[:actual], "selectivity" => shape[:selectivity], "depth" => depth,
        "shared_hit_blocks" => shape[:hit], "shared_read_blocks" => shape[:read],
        "actual_total_time" => shape[:time], "actual_loops" => shape[:loops] }
    end

    # Each plan table in the section, by its rows.
    def plan_rows(html) = html.scan(%r{<table class="plan">.*?</table>}m).map { it.scan(%r{<tr.*?</tr>}m).drop(1) }

    # Each cell's opening tag in a plan row.
    def cell_tags(row) = row.scan(/<td[^>]*>/)

    # Each row's misestimate class in the first plan table, or nil for a row with none: the class its estimated
    # and actual rows cells share, failing if they don't, or if the row or another cell has one.
    def shades(html) = plan_rows(html).first.map { row_shade(it) }

    def row_shade(row)
      tags = cell_tags(row)
      est, actual = tags.values_at(3, 4).map { it[/misestimate-\d/] }
      expect(est).to eq(actual)
      expect([row[/\A<tr[^>]*>/], *tags.values_at(0, 1, 2, 5, 6, 7).compact].join).not_to include("misestimate")
      est
    end

    # The text of a plan row's last cell.
    def last_cell(row) = row[%r{>([^<]*)</td></tr>\z}, 1]

    # Each row's time cell in the first plan table.
    def times(html) = plan_rows(html).first.map { last_cell(it) }

    # Each row's own-share class on its blocks cell (index 6) or time cell (index 7) in the first plan table.
    def cost_shades(html, index) = plan_rows(html).first.map { cell_tags(it)[index][/cost-\d/] }

    let(:header) do
      '<tr><th scope="col">Step</th><th scope="col">Table</th><th scope="col">Index</th>' \
        '<th scope="col" class="num">Estimated rows</th><th scope="col" class="num">Actual rows</th>' \
        '<th scope="col" class="num">Share of the table</th>' \
        '<th scope="col" class="num">Blocks read, with the steps under it</th>'
    end
    let(:time_header) { '<th scope="col" class="num">Time in the step itself</th>' }

    it "explains the winner from blocks, with each plan as a table of its steps" do
      expect(explanation).to include("Rewrite Vivid Cove with no new indices read 300 blocks on the slow values, " \
                                     "against 1,000 for the original query (70% fewer).")
      expect(explanation).to include("<p>How it runs rewrite Vivid Cove with no new indices:</p>")
      expect(explanation.scan("#{header}#{time_header}</tr>").size).to eq(1)
      expect(explanation.scan("#{header}</tr>").size).to eq(1)
      expect(plan_rows(explanation)).to eq(
        [[[%(<tr><td class="step" style="padding-left: 0.65rem">Seq Scan</td><td>#{sq("public.t")}</td><td></td>),
           %(<td class="num">50</td><td class="num">50</td><td class="num">5.0%</td>),
           %(<td class="num cost-8" title="1,234 blocks in the step itself, 100% of the plan&#39;s">1,234</td>),
           %(<td class="num cost-8" title="12.5 ms in the step itself, 100% of the plan&#39;s">12.5 ms (100%)</td>),
           %(</tr>)].join],
         [[%(<tr><td class="step" style="padding-left: 0.65rem">Index Scan</td><td>#{sq("public.t")}</td>),
           %(<td>#{sq("t_a_idx")}</td><td class="num">5</td><td class="missing">not recorded</td>),
           %(<td class="num">0.5%</td><td class="missing">not recorded</td></tr>)].join]]
      )
      expect(explanation).not_to include("<li>")
    end

    it "marks no step as differing from the other plan, in words, by class, or in the stylesheet" do
      payload["original_plan"] = [pnode("Limit", 0), pnode("Sort", 1), pnode("Seq Scan", 2, relation: "public.t")]
      expect(explanation).not_to match(/differs|class="mark"/i)
      expect(html[%r{<style>(.*?)</style>}m, 1]).not_to match(/differs|\.mark\b/)
    end

    it "indents each step by its depth, under an arrow" do
      payload["original_plan"] = [pnode("Limit", 0), pnode("Nested Loop", 1),
                                  pnode("Seq Scan", 2, relation: "public.t", est: 9_000, actual: 12_345,
                                                       selectivity: 0.5)]
      expect(plan_rows(explanation).first).to eq(
        [[%(<tr><td class="step" style="padding-left: 0.65rem">Limit</td><td></td><td></td>),
          %(<td class="num">10</td><td class="num">10</td><td class="num"></td><td class="num">7</td></tr>)].join,
         [%(<tr><td class="step" style="padding-left: 2.15rem"><span class="arrow" aria-hidden="true">-&gt; </span>),
          %(Nested Loop</td><td></td><td></td><td class="num">10</td><td class="num">10</td>),
          %(<td class="num"></td><td class="num">7</td></tr>)].join,
         [%(<tr><td class="step" style="padding-left: 3.65rem"><span class="arrow" aria-hidden="true">-&gt; </span>),
          %(Seq Scan</td><td>#{sq("public.t")}</td><td></td><td class="num">9,000</td><td class="num">12,345</td>),
          %(<td class="num">50.0%</td>),
          %(<td class="num cost-8" title="7 blocks in the step itself, 100% of the plan&#39;s">7</td></tr>)].join]
      )
    end

    describe "shading each step by how far its estimated rows are from its actual rows" do
      def shaded(*pairs, **) = pairs.map { |est, actual| pnode("Seq Scan", 0, est:, actual:, **) }

      it "shades from 2x, 5x, 10x, 20x, 50x, 100x, and 500x off, and over 1000x, either way" do
        payload["original_plan"] = shaded([10, 19.99], [10, 20], [20, 10], [50, 10.1], [50, 10], [10, 50],
                                          [100, 10.01], [10, 100], [100, 10], [1, 19.9], [1, 20], [20, 1],
                                          [49.9, 1], [50, 1], [1, 50], [1, 99.9], [1, 100], [100, 1],
                                          [499, 1], [500, 1], [1, 500], [1, 1000], [1000, 1], [1, 1000.5],
                                          [1001, 1], [1, 2_000_000])
        expect(shades(explanation)).to eq(
          [nil, *%w[1 1 1 2 2 2 3 3 3 4 4 4 5 5 5 6 6 6 7 7 7 7 8 8 8].map { "misestimate-#{it}" }]
        )
      end

      it "counts a row count under 1 as 1, so an estimate of 1 against no actual rows isn't shaded" do
        payload["original_plan"] = shaded([1, 0], [0, 0], [1, 0.4], [0, 0.5], [2, 0], [0, 5], [5, 0.2])
        expect(shades(explanation)).to eq([nil, nil, nil, nil, "misestimate-1", "misestimate-2", "misestimate-2"])
      end

      it "doesn't shade a step that never ran, or one without both row counts" do
        payload["original_plan"] = [*shaded([100, 0], loops: 0), *shaded([100, nil], [nil, 1]),
                                    *shaded([100, 1], loops: nil)]
        expect(shades(explanation)).to eq([nil, nil, nil, "misestimate-6"])
      end

      it "says how far off a shaded step is in the title of its row count cells, and leaves the row unshaded" do
        payload["original_plan"] = shaded([10, 20], [1, 1001], [1, 1])
        expect(plan_rows(explanation).first.map { it[/\A<tr[^>]*>/] }).to eq(%w[<tr> <tr> <tr>])
        expect(plan_rows(explanation).first.map { cell_tags(it).values_at(3, 4) }).to eq(
          [['<td class="num misestimate-1" title="Estimated rows off by 2x or more">'] * 2,
           ['<td class="num misestimate-8" title="Estimated rows off by over 1000x">'] * 2,
           ['<td class="num">'] * 2]
        )
      end

      it "doesn't shade a plan Postgres only estimated" do
        expect(plan_rows(explanation).last.first).not_to include("misestimate")
      end

      it "shades the winner's measured plan too" do
        payload["labels"].each { it["plan"] = nil }
        payload["labels"].find { it["label"] == "rewrite_1:none" }["plan"] = shaded([1, 300])
        expect(cell_tags(plan_rows(explanation).last.first)[4]).to start_with('<td class="num misestimate-6"')
      end

      it "says what the shading means, once, with a swatch for each step of it" do
        legend = '<p class="note legend">Each step&#39;s estimated and actual rows are shaded by how far apart ' \
                 "they were, per loop, either way: " \
                 '<span class="misestimate-1">2x</span> <span class="misestimate-2">5x</span> ' \
                 '<span class="misestimate-3">10x</span> <span class="misestimate-4">20x</span> ' \
                 '<span class="misestimate-5">50x</span> <span class="misestimate-6">100x</span> ' \
                 '<span class="misestimate-7">500x</span> <span class="misestimate-8">over 1000x</span>. ' \
                 "A count under 1 counts as 1, so an estimate of 1 row against none isn&#39;t shaded, and " \
                 "neither is a step that never ran.</p>"
        expect(explanation).to include("#{legend}<p class=\"note legend\">Blocks read and time are shaded")
        expect(explanation.scan(legend).size).to eq(1)
      end

      it "says nothing of shading when no plan it shows has actual rows" do
        payload["original_plan"] = shaded([10, nil])
        expect(explanation).not_to include("misestimate")
      end

      it "gets redder, step by step, in both themes, with the text readable on each" do
        theme_variables.each do |name, v|
          shades = (1..8).map { v["--misestimate-#{it}"] }
          expect(shades).to all(match(/\A#\h{6}\z/)), "#{name}: #{shades}"
          against_page = shades.map { contrast(it, v["--bg"]) }
          expect(against_page.each_cons(2)).to all(satisfy { |a, b| b > a }), "#{name}: #{against_page}"
          shades.each do |shade|
            expect(rgb(shade).then { |r, g, b| r > g && r > b }).to be(true), shade
            expect(contrast(v["--text"], shade)).to be >= 4.5, "#{name} --text on #{shade}"
          end
        end
        expect(theme_variables[:light]["--misestimate-8"]).not_to eq(theme_variables[:dark]["--misestimate-8"])
        style = html[%r{<style>(.*?)</style>}m, 1]
        (1..8).each do |n|
          expect(style).to include("table.plan td.misestimate-#{n}, .legend .misestimate-#{n} " \
                                   "{ background: var(--misestimate-#{n}); }")
        end
        expect(style).not_to include("tr.misestimate")
      end
    end

    describe "shading each step's blocks and time by its own share of the plan's" do
      def flat(*blocks, **) = blocks.map { pnode("Seq Scan", 0, hit: it, read: 0, **) }

      it "shades blocks from 5%, 10%, 20%, 30%, 40%, 50%, 65%, and 80% of the plan's, and not under 5%" do
        expected = { [44, 45, 911] => [nil, 1, 8], [50, 950] => [1, 8], [100, 194, 706] => [2, 2, 7],
                     [200, 300, 500] => [3, 4, 6], [394, 606] => [4, 6], [395, 605] => [5, 6],
                     [644, 356] => [6, 4], [645, 355] => [7, 4], [794, 206] => [7, 3], [795, 205] => [8, 3] }
        expected.each do |blocks, buckets|
          payload["original_plan"] = flat(*blocks)
          expect(cost_shades(section(render(payload), "explanation"), 6))
            .to eq(buckets.map { it && "cost-#{it}" }), blocks.inspect
        end
      end

      it "counts a step's own blocks, without the blocks of the steps directly under it, never below zero" do
        payload["original_plan"] = [pnode("Limit", 0, hit: 900, read: 100), pnode("Hash Join", 1, hit: 900, read: 100),
                                    pnode("Seq Scan", 2, hit: 600, read: 100), pnode("Hash", 2, hit: 300, read: 0),
                                    pnode("Seq Scan", 3, hit: 300, read: 0),
                                    pnode("Result", 1, hit: 0, read: 0), pnode("Seq Scan", 2, hit: 20, read: 0)]
        expect(cost_shades(explanation, 6)).to eq([nil, nil, "cost-7", nil, "cost-3", nil, nil])
        expect(cell_tags(plan_rows(explanation).first[2])[6])
          .to eq('<td class="num cost-7" title="700 blocks in the step itself, 69% of the plan&#39;s">')
      end

      it "doesn't shade a step whose own blocks it can't count, and leaves them out of the plan's" do
        payload["original_plan"] = [pnode("Limit", 0, hit: 1000, read: 0), pnode("Seq Scan", 1, hit: nil),
                                    pnode("Seq Scan", 0, hit: 100, read: 0), pnode("Seq Scan", 0, hit: 300, read: 0)]
        expect(cost_shades(explanation, 6)).to eq([nil, nil, "cost-3", "cost-7"])
      end

      it "shades a step's own time over all its loops the same way, by its share of the plan's" do
        payload["original_plan"] = [pnode("Limit", 0, time: 12.0), pnode("Nested Loop", 1, time: 9.5),
                                    pnode("Seq Scan", 2, time: 2.0), pnode("Index Scan", 2, time: 0.05, loops: 100),
                                    pnode("Result", 1, time: 0.25, loops: 2), pnode("Function Scan", 2, time: 0.1),
                                    pnode("Seq Scan", 0, time: nil)]
        expect(cost_shades(explanation, 7)).to eq(["cost-2", "cost-3", "cost-2", "cost-5", nil, nil, nil])
        expect(cell_tags(plan_rows(explanation).first[3])[7])
          .to eq('<td class="num cost-5" title="5.0 ms in the step itself, 42% of the plan&#39;s">')
      end

      it "buckets a step by its share as the cell rounds it, so the cell and the legend agree" do
        payload["original_plan"] = [pnode("Seq Scan", 0, time: 4.96), pnode("Seq Scan", 0, time: 19.6),
                                    pnode("Seq Scan", 0, time: 4.44), pnode("Seq Scan", 0, time: 71.0)]
        expect(cost_shades(explanation, 7)).to eq(["cost-1", "cost-3", nil, "cost-7"])
        expect(cell_tags(plan_rows(explanation).first[0])[7])
          .to eq('<td class="num cost-1" title="5.0 ms in the step itself, 5% of the plan&#39;s">')
        expect(plan_rows(explanation).first[0]).to include("5.0 ms (5%)")
      end

      it "shades nothing in a plan whose steps took no time or read no blocks" do
        payload["original_plan"] = [pnode("Result", 0, time: 0.0, hit: 0, read: 0)]
        expect(plan_rows(explanation).first.first).not_to include("cost-")
      end

      it "doesn't shade a plan Postgres only estimated" do
        expect(plan_rows(explanation).last.first).not_to include("cost-")
      end

      it "says what the shading means, once, with a swatch for each step of it" do
        legend = '<p class="note legend">Blocks read and time are shaded by how much of the plan&#39;s each step ' \
                 "did itself, without the steps under it: " \
                 '<span class="cost-1">5%</span> <span class="cost-2">10%</span> ' \
                 '<span class="cost-3">20%</span> <span class="cost-4">30%</span> ' \
                 '<span class="cost-5">40%</span> <span class="cost-6">50%</span> ' \
                 '<span class="cost-7">65%</span> <span class="cost-8">80%</span> or more. ' \
                 "So a step whose blocks read are high only because of the steps under it isn&#39;t shaded.</p>"
        expect(explanation).to include("#{legend}<p>How Postgres runs the original query now:</p>")
        expect(explanation.scan("cost-1\">5%").size).to eq(1)
      end

      it "says nothing of it when no plan it shows has blocks or times" do
        payload["original_plan"] = [pnode("Seq Scan", 0, hit: nil, read: nil)]
        expect(explanation).not_to include("cost-")
      end

      it "gets darker amber, step by step, in both themes, with the text readable on each" do
        theme_variables.each do |name, v|
          shades = (1..8).map { v["--cost-#{it}"] }
          expect(shades).to all(match(/\A#\h{6}\z/)), "#{name}: #{shades}"
          against_page = shades.map { contrast(it, v["--bg"]) }
          expect(against_page.each_cons(2)).to all(satisfy { |a, b| b > a }), "#{name}: #{against_page}"
          shades.each do |shade|
            expect(rgb(shade).then { |r, g, b| r > g && g > b }).to be(true), shade
            expect(contrast(v["--text"], shade)).to be >= 4.5, "#{name} --text on #{shade}"
          end
        end
        style = html[%r{<style>(.*?)</style>}m, 1]
        (1..8).each do |n|
          expect(style).to include("table.plan td.cost-#{n}, .legend .cost-#{n} { background: var(--cost-#{n}); }")
        end
      end
    end

    describe "the time in each step" do
      it "is its own time over all its loops, without the steps under it, and its share of the plan's" do
        payload["original_plan"] = [pnode("Limit", 0, time: 12.0), pnode("Nested Loop", 1, time: 9.5),
                                    pnode("Seq Scan", 2, time: 2.0), pnode("Index Scan", 2, time: 0.05, loops: 100),
                                    pnode("Result", 1, time: 0.25, loops: 2), pnode("Function Scan", 2, time: 0.1)]
        expect(times(explanation)).to eq(["2.0 ms (17%)", "2.5 ms (21%)", "2.0 ms (17%)", "5.0 ms (42%)",
                                          "0.4 ms (3%)", "0.1 ms (1%)"])
      end

      it "takes no time below zero, as when parallel workers' times add up to more than the Gather's" do
        payload["original_plan"] = [pnode("Gather", 0, time: 5.0), pnode("Parallel Seq Scan", 1, time: 4.0, loops: 3)]
        expect(times(explanation)).to eq(["0.0 ms (0%)", "12.0 ms (100%)"])
      end

      it "says a time too small to round, and leaves out the share when the plan took no time" do
        payload["original_plan"] = [pnode("Result", 0, time: 0.04)]
        expect(times(explanation)).to eq(["under 0.1 ms (100%)"])
        payload["original_plan"] = [pnode("Result", 0, time: 0.0)]
        expect(times(section(render(payload), "explanation"))).to eq(["0.0 ms"])
      end

      it "isn't recorded for a step without its time or loops, or whose steps under it lack one" do
        payload["original_plan"] = [pnode("Limit", 0, time: 3.0), pnode("Sort", 1, time: nil),
                                    pnode("Seq Scan", 2, time: 1.0), pnode("Hash", 1, time: 1.0, loops: nil)]
        expect(times(explanation)).to eq(["not recorded", "not recorded", "1.0 ms (100%)", "not recorded"])
      end

      it "is left out, with its column, for a plan with no times" do
        expect(explanation.scan(time_header).size).to eq(1)
        payload["original_plan"].first["actual_total_time"] = nil
        untimed = section(render(payload), "explanation")
        expect(untimed).not_to include(time_header)
        expect(untimed).not_to include("Time in a step")
      end

      it "says, under the original query's plan, how parallel workers and subqueries count" do
        note = "<p class=\"note\">Time in a step is over all its loops, without the steps under it. With parallel " \
               "workers, a step adds up each worker&#39;s time, so the steps can add up to more than the query " \
               "took, and the Gather above them can show none. A subquery, InitPlan, or CTE&#39;s time comes off " \
               "the step it&#39;s listed under, but Postgres counts it in the step that used its result, so one " \
               "can show too little time and the other too much.</p>"
        expect(explanation.scan(note).size).to eq(1)
        expect(explanation)
          .to match(%r{</table><p class="note">Blocks read[^\n]*</p>\n#{Regexp.escape(note)}\n<p>QUAACK})
      end
    end

    it "says, under the original query's plan, that blocks count every loop and an InitPlan's can show twice" do
      note = "<p class=\"note\">Blocks read count every time a step ran, while actual rows are for one run, so " \
             "a step that ran many times can show one row next to thousands of blocks. And a subquery Postgres " \
             "runs once up front (an InitPlan) has its blocks counted in the step that used its result, which " \
             "needn&#39;t be the step it&#39;s listed under, so those blocks can show up twice.</p>"
      expect(explanation).to include("</table>#{note}\n<p class=\"note\">Time in a step")
      expect(explanation.scan(note).size).to eq(1)
    end

    it "says one row, a share too small to round, and a row count it doesn't have" do
      payload["original_plan"] = [pnode("Index Scan", 0, relation: "public.t", index: "t_pkey", est: 1, actual: 1,
                                                         selectivity: 0.000001),
                                  pnode("Limit", 1, est: 12_345, actual: nil)]
      rows = plan_rows(explanation).first
      expect(rows.first).to include(%(<td class="num">1</td><td class="num">1</td><td class="num">under 0.1%</td>))
      expect(rows.last).to include(%(<td class="num">12,345</td><td class="missing">not recorded</td>))
    end

    it "says a step's blocks read as its shared hit and read blocks together, or not recorded without both" do
      payload["original_plan"] = [[12_000, 345], [0, 0], [nil, 9], [8, nil], [nil, nil]].map do |hit, read|
        pnode("Seq Scan", 0, hit:, read:)
      end
      expect(plan_rows(explanation).first.map { last_cell(it) })
        .to eq(["12,345", "0", "not recorded", "not recorded", "not recorded"])
    end

    it "says a share is under 0.1% only when it is above zero and would round to 0.0%" do
      payload["original_plan"] = [0.0, 0.0004, 0.0005, 0.004].map { pnode("Seq Scan", 0, selectivity: it) }
      expect(plan_rows(explanation).first.map { it[%r{<td class="num">([^<]*)</td><td class="num[^>]*>7</td>}, 1] })
        .to eq(["0.0%", "under 0.1%", "0.1%", "0.4%"])
    end

    it "says the winner's plan wasn't recorded when the winner is the original query with new indices" do
      payload["top"].reverse!
      expect(explanation).to include("The plan with the new indices: not recorded.")
      expect(explanation).not_to include("t_a_idx")
      expect(plan_rows(explanation).size).to eq(1)
    end

    it "says why the winner's blocks aren't recorded when the run kept no measured plan for it" do
      expect(explanation).to include(
        "<p>QUAACK has no measured plan for the winner, so the blocks it read at each step aren&#39;t recorded. " \
        "The plan below is the one Postgres expected, " \
        "from EXPLAIN without running the query, which counts no blocks.</p>\n<p>How it runs rewrite Vivid Cove"
      )
    end

    it "says why there is no plan with the new indices when the run kept no measured plan for the winner" do
      payload["top"].reverse!
      expect(explanation).to include("<p>#{ERB::Util.html_escape(described_class::View::NO_MEASURED_PLAN)}</p>")
      expect(explanation).not_to include(ERB::Util.html_escape(described_class::View::ESTIMATED_PLAN))
    end

    context "with the winner's measured plan" do
      before do
        payload["labels"].each { it["plan"] = nil }
        payload["labels"].find { it["label"] == "rewrite_1:none" }["plan"] =
          [pnode("Limit", 0, hit: 250, read: 50), pnode("Index Scan", 1, relation: "public.t", index: "t_a_idx",
                                                                         hit: 240, read: 50)]
        payload["labels"].find { it["label"] == "original:top:1" }["plan"] =
          [pnode("Index Scan", 0, relation: "public.t", index: "quaack_a", hit: 300, read: 100)]
      end

      it "shows it, with its blocks, in place of the plan Postgres expected" do
        expect(explanation).to include("<p>How it runs rewrite Vivid Cove with no new indices, as QUAACK measured " \
                                       "it on the slow values:</p>")
        expect(explanation).not_to include("How it runs rewrite Vivid Cove with no new indices:</p>")
        expect(plan_rows(explanation).size).to eq(2)
        expect(plan_rows(explanation).last.map { last_cell(it) }).to eq(%w[300 290])
        expect(plan_rows(explanation).last.last).to include("<td>#{sq("t_a_idx")}</td>")
        expect(explanation).not_to include(ERB::Util.html_escape(described_class::View::NO_MEASURED_PLAN))
        expect(explanation).not_to include(ERB::Util.html_escape(described_class::View::ESTIMATED_PLAN))
      end

      it "shows the plan with the new indices when the winner is the original query with them" do
        payload["top"].reverse!
        expect(explanation).to include("<p>How it runs the original query with ")
        expect(explanation).not_to include("The plan with the new indices: not recorded.")
        expect(plan_rows(explanation).size).to eq(2)
        expect(plan_rows(explanation).last.first).to include("<td>#{sq("quaack_a")}</td>")
        expect(plan_rows(explanation).last.first).to include(
          %(<td class="num cost-8" title="400 blocks in the step itself, 100% of the plan&#39;s">400</td></tr>)
        )
      end

      context "and its times" do
        let(:winner_note) do
          "<p class=\"note\">#{ERB::Util.html_escape(described_class::Plans::WINNER_TIMED_NOTE)}</p>"
        end

        def untimed_note(result)
          "<p class=\"note\">#{ERB::Util.html_escape(described_class::Plans::WINNER_UNTIMED.fetch(result))}</p>"
        end

        def time_note = "<p class=\"note\">#{ERB::Util.html_escape(described_class::Plans::TIME_NOTE)}</p>"

        before do
          payload["original_plan"].first["actual_total_time"] = nil
          plan = payload["labels"].find { it["label"] == "rewrite_1:none" }["plan"]
          plan.zip([3.0, 1.0]) { |node, time| node["actual_total_time"] = time }
          payload["winner_timing"] = "timed"
        end

        it "shows each step's time in the winner's plan, says where the times came from and how they count" do
          expect(plan_rows(explanation).last.map { last_cell(it) }).to eq(["2.0 ms (67%)", "1.0 ms (33%)"])
          expect(explanation).to end_with("</table>#{winner_note}\n#{time_note}\n</section>")
          expect(explanation.scan(time_note).size).to eq(1)
        end

        it "says how times count only once, under the original's plan, when both plans have times" do
          payload["original_plan"].first["actual_total_time"] = 12.5
          expect(explanation.scan(time_note).size).to eq(1)
          expect(explanation).to match(%r{</table>#{Regexp.escape(winner_note)}\n</section>})
        end

        %w[timed_out failed plan_differs].each do |result|
          it "says why the winner's plan has no times when its timed run was #{result}" do
            payload["labels"].find { it["label"] == "rewrite_1:none" }["plan"].each { it["actual_total_time"] = nil }
            payload["winner_timing"] = result
            expect(explanation).to match(%r{</table>#{Regexp.escape(untimed_note(result))}\n</section>})
            expect(explanation).not_to include(winner_note, "Time in a step")
          end
        end

        it "says nothing of the winner's times when the run didn't time it" do
          payload["labels"].find { it["label"] == "rewrite_1:none" }["plan"].each { it["actual_total_time"] = nil }
          payload.delete("winner_timing")
          expect(explanation).to end_with("</table></section>")
          expect(explanation).not_to include(winner_note, "Time in a step", "timed run")
        end
      end
    end

    it "is left out when nothing beat the original" do
      expect(render(negative_payload)).not_to include('id="explanation"')
    end
  end

  describe "the index table" do
    let(:indexes) { section(html, "indexes") }

    it "lists the ranked candidates' indices as proposed, and the rest as built and measured" do
      other = "<h3>Other indices QUAACK built and measured</h3>"
      expect(indexes).to match(%r{<h2>Proposed indices</h2>.*btree \(created_at\).*#{other}.*btree \(a, b\)}m)
      expect(indexes.scan("<table").size).to eq(2)
    end

    it "gives each index its size, and the existing index that covers it with its size, in the last two columns" do
      expect(indexes).to include(
        "<tr><td>#{sq("CREATE INDEX ON public.t USING btree (created_at)")}</td><td class=\"num\">8 kB</td>" \
        "<td>#{sq("t_created_at_id_idx")} (40 kB)</td></tr>"
      )
      expect(indexes).to include('<td class="num">16 kB</td><td>none</td></tr>')
      expect(indexes).not_to include("make redundant", "makes_redundant")
    end

    it "uses the unit that fits, with thousands separators" do
      sizes = { 1_024_000 => "1,000 kB", 54_456 * 1024 => "53.2 MB", 313_776 * 1024 => "306.4 MB",
                12_687_440 * 1024 => "12.1 GB", 2_000_000 * 1024 * 1024 => "1,953.1 GB", 0 => "0 kB" }
      sizes.each do |bytes, text|
        payload["indexes"]["quaack_a"]["size"] = bytes
        expect(section(render(payload), "indexes")).to include(%(<td class="num">#{text}</td>))
      end
    end

    it "moves to the next unit just where the number would round to 1,024 of the one before" do
      mb = 1024 * 1024
      sizes = { (1023 * 1024) + 511 => "1,023 kB", (1023 * 1024) + 512 => "1.0 MB",
                (1023 * mb) + (mb * 0.94).to_i => "1,023.9 MB", (1023 * mb) + (mb * 0.96).to_i => "1.0 GB" }
      sizes.each do |bytes, text|
        payload["indexes"]["quaack_a"]["size"] = bytes
        expect(section(render(payload), "indexes")).to include(%(<td class="num">#{text}</td>))
      end
    end

    it "lists only the indices the payload carries, whatever a label names" do
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

    it "calls a negative result's table what it is, not proposed indices" do
      indexes = section(render(negative_payload), "indexes")
      expect(indexes).to include("<h2>Indices QUAACK built and measured</h2>")
      expect(indexes).to include("btree (created_at)").and include("btree (a, b)")
      expect(render(negative_payload)).not_to match(/Proposed indices|Other indices/)
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
      expect(bug_html.scan(/<section id="([a-z-]+)"[^>]*>/).flatten.first(2)).to eq(%w[quaack-bugs summary])
      expect(bug_section).to include("<h2>QUAACK bug: a rule made a wrong rewrite</h2>")
      expect(bug_section).to include("a rule has a bug")
      sentence = "<p>The transform rules are meant to be sound: a rewrite one makes should return the same rows as " \
                 "the original query on any data. A test proved each rewrite below wrong, so a rule has a bug. " \
                 "QUAACK dropped these rewrites, and the rest of this report still holds. Please report this, " \
                 "with the names of the rules.</p>"
      expect(bug_section).to include(esc(sentence))
      expect(bug_section).not_to include("mechanical")
    end

    it "names each rewrite, the rules that made it, and the test that proved it wrong" do
      expect(bug_section).to include(esc("<li>Rewrite Smooth Kayak, made by transform rule " \
                                         "key_in_self_join, returned different results on made-up test data.</li>"))
      expect(bug_section).to include(esc("<li>Rewrite Dainty Bloom, made by transform rules " \
                                         "or_to_union, then key_in_self_join, returned different results on test " \
                                         "data the LLM wrote to break it.</li>"))
      expect(bug_section).to include(esc("<li>Rewrite Odd Mitten, made by transform rule &lt;b&gt;, " \
                                         "returned different results on the real data.</li>"))
      expect(bug_section).not_to include("<b>")
    end

    # Task 20261012-2. Its entry doesn't say how fuzz proved it wrong, and
    # fuzz also disproves a rewrite that fails where the original ran.
    it "names a rule-made rewrite a random small database proved wrong" do
      fuzzed = render(payload.merge("rule_bugs" => [{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"],
                                                      "step" => "fuzz" }]))
      expect(section(fuzzed, "quaack-bugs"))
        .to include(esc("<li>Rewrite Smooth Kayak, made by transform rule key_in_self_join, was proved wrong " \
                        "on a random small database built around its own values.</li>"))
    end

    # Task 20261012-3.
    it "names a rule-made rewrite a small database QUAACK enumerated proved wrong" do
      enumerated = render(payload.merge("rule_bugs" => [{ "rewrite" => "rewrite_2", "rules" => ["key_in_self_join"],
                                                          "step" => "enumerate" }]))
      expect(section(enumerated, "quaack-bugs"))
        .to include(esc("<li>Rewrite Smooth Kayak, made by transform rule key_in_self_join, was proved wrong " \
                        "on a small database QUAACK enumerated from its own values.</li>"))
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
      expect(negative_html.scan(/<section id="([a-z-]+)"[^>]*>/).flatten)
        .to eq(%w[summary queries ranking timeouts negative-result indexes accountability burndown])
      expect(html).not_to include("negative-result")
    end

    it "makes the rewrites, declined, and existing lists rose folds, the last two starting collapsed" do
      folds = why.scan(%r{<details class="fold rose" id="([a-z-]+)"( open)?>\s*<summary><h3>(.*?)</h3></summary>})
      expect(folds).to eq([["ideas-rewrites", " open", "The rewrites"],
                           ["ideas-declined", nil, "Indices the planner wouldn't use"],
                           ["ideas-existing", nil, "Indices QUAACK thought of that you already have"]])
      expect(why.scan("<details").size).to eq(3)
      expect(why.scan("</details>").size).to eq(3)
      expect(why[%r{<details[^>]*id="ideas-rewrites".*?</details>}m]).to include('<ul id="negative-rewrites">')
    end

    it "spaces the rewrites list, a direct child of its fold, off the summary" do
      expect(why[%r{<details[^>]*id="ideas-rewrites".*?</details>}m])
        .to match(%r{</summary>\s*<ul id="negative-rewrites">})
      expect(negative_html).to match(/details\.fold > [^{]*\bul\b[^{]*\{ margin-top: 0\.5rem; \}/)
    end

    it "says what became of every rewrite, with its source, in words" do
      list = why[%r{<ul id="negative-rewrites">.*?</ul>}m]
      expect(list.scan(/<li>(Rewrite [^(]+) \(/).flatten)
        .to eq(["Rewrite Smooth Kayak", "Rewrite Dainty Bloom", "Rewrite Bright Island", "Rewrite Trim Falcon",
                "Rewrite Wise Slipper"])
      expect(list).to include(esc("<li>Rewrite Smooth Kayak (source not recorded): It returned different results " \
                                  "from the original query on made-up test data, so it's wrong.</li>"))
      expect(list).to include("<li>Rewrite Dainty Bloom (suggested by the LLM): It returned different results")
      expect(list)
        .to include(esc("<li>Rewrite Bright Island (made by transform rule key_in_self_join): It passed"))
      expect(list).to include("<li>Rewrite Trim Falcon (your own rewrite): Postgres plans it exactly as")
      expect(list).to include("<li>Rewrite Wise Slipper (source not recorded): A test on made-up data ended without " \
                              "comparing results")
    end

    it "labels a rule-made rewrite that rewrite-test disproved with its rules" do
      line = fated(2, "rewrite_test_disproved", scenario: "s3", rule: "multiset", source: "rule",
                                                rules: %w[or_to_union key_in_self_join])
      list = section(render(negative_payload.merge("rewrites" => [line])), "negative-result")
      expect(list).to include(esc("<li>Rewrite Smooth Kayak (made by transform rules or_to_union, then " \
                                  "key_in_self_join): It returned different results from the original query on " \
                                  "made-up test data, so it's wrong.</li>"))
    end

    it "says so when no rewrite was kept" do
      expect(section(render(negative_payload.merge("rewrites" => [])), "negative-result"))
        .to include("QUAACK kept no rewrite to test.")
    end

    it "says which indices the planner wouldn't use, and why, once each" do
      table = why[%r{<table id="declined-indexes">.*?</table>}m]
      expect(table).to include("<tr><td>#{sq("CREATE INDEX ON public.t USING btree (a) WHERE a &lt; ?")}</td>" \
                               "<td>The planner never chose it.</td></tr>")
      expect(table).to include(esc("<tr><td>#{sq("CREATE INDEX ON public.t USING gin (b)")}</td>" \
                                   "<td>HypoPG, which QUAACK uses to try an index " \
                                   "without building it, couldn't create it (Postgres error code 0A000).</td></tr>"))
      expect(table).to include(esc("<tr><td>an index QUAACK couldn't write out</td>" \
                                   "<td>QUAACK couldn't write its definition.</td></tr>"))
    end

    it "leaves out an error code the payload doesn't have, with no empty brackets" do
      negative["declined"][1]["sqlstate"] = nil
      expect(why).to include(esc("without building it, couldn't create it.</td>"))
    end

    it "says a decline's reason wasn't recorded when the payload has none" do
      negative["declined"] = [{ "ddl" => "CREATE INDEX ON public.t USING btree (z)", "reason" => nil,
                                "sqlstate" => nil, "searches" => ["original"] }]
      expect(why).to include("<td>not recorded</td></tr>")
    end

    it "says which suggested indices already existed, with the existing index, its definition, and its size" do
      table = why[%r{<table id="existing-indexes">.*?</table>}m]
      expect(table).to include("<tr><td>#{sq("CREATE INDEX ON public.t USING btree (c)")}</td>" \
                               "<td>#{sq("t_c_d_idx")}<br>" \
                               "#{sq("CREATE INDEX ON public.t USING btree (c, d) WHERE d = ?")}</td>" \
                               '<td class="num">3.0 MB</td></tr>')
    end

    it "shows just the name when the payload has no definition for the existing index" do
      negative["existing"][0]["covered_by"].delete("definition")
      table = why[%r{<table id="existing-indexes">.*?</table>}m]
      expect(table).to include("<td>#{sq("t_c_d_idx")}</td>")
      expect(table).not_to include("<br>")
    end

    it "has no Tried for column in either index table, and keeps the other columns" do
      declined = why[%r{<table id="declined-indexes">.*?</table>}m]
      existing = why[%r{<table id="existing-indexes">.*?</table>}m]
      expect(declined).to include('<thead><tr><th scope="col">Index</th><th scope="col">Why not</th></tr></thead>')
      expect(existing).to include('<thead><tr><th scope="col">Index</th><th scope="col">Your index that covers it' \
                                  '</th><th scope="col" class="num">Its size</th></tr></thead>')
      expect(declined + existing).not_to include("Tried for")
      expect(declined + existing).not_to include("rewrite Vivid Cove")
      expect(why).not_to include("every query it was tried for")
    end

    it "says none when no index was declined or already existed" do
      negative.merge!("declined" => [], "existing" => [])
      expect(why).to include("The planner would have used every index QUAACK thought of.")
      expect(why).to include("None of the indices QUAACK thought of already existed.")
      expect(why).not_to include("<table")
    end
  end

  # Task 20261003-5: a winning report's payload carries the declined and
  # existing lists too.
  describe "when a candidate won and the payload lists declined and existing indices" do
    let(:winning) { render(payload.merge("negative" => negative)) }
    let(:ideas) { section(winning, "index-ideas") }

    it "lists them in their own section, after the explanation, with no rewrites' fates" do
      expect(winning.scan(/<section id="([a-z-]+)"[^>]*>/).flatten)
        .to eq(%w[summary queries ranking timeouts explanation index-ideas indexes accountability burndown])
      expect(ideas).to include("<h2>Index ideas that went nowhere</h2>")
      expect(winning).not_to include("negative-result")
      expect(winning).not_to include("negative-rewrites")
    end

    it "says which indices the planner wouldn't use and which already existed, as a negative result does" do
      negative_html = render(negative_payload)
      %w[declined-indexes existing-indexes].each do |id|
        table = ideas[%r{<table id="#{id}">.*?</table>}m]
        expect(table).not_to be_nil
        expect(table).to eq(section(negative_html, "negative-result")[%r{<table id="#{id}">.*?</table>}m])
      end
      expect(ideas).to include("<td>#{sq("t_c_d_idx")}<br>")
    end

    it "makes the declined and existing lists rose folds that start collapsed, and that a link opens" do
      folds = ideas.scan(%r{<details class="fold rose" id="([a-z-]+)"( open)?>\s*<summary><h3>(.*?)</h3></summary>})
      expect(folds).to eq([["ideas-declined", nil, "Indices the planner wouldn't use"],
                           ["ideas-existing", nil, "Indices QUAACK thought of that you already have"]])
      expect(ideas.scan("<details").size).to eq(2)
      expect(ideas.scan("</details>").size).to eq(2)
      expect(ideas[%r{<details[^>]*id="ideas-declined".*?</details>}m]).to include('<table id="declined-indexes">')
      expect(ideas[%r{<details[^>]*id="ideas-existing".*?</details>}m]).to include('<table id="existing-indexes">')
    end

    it "leaves the section out when the payload has no lists" do
      expect(html).not_to include("index-ideas")
    end
  end

  describe "who proposed what" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    def rows(html, id)
      table = html[%r{<table id="accountability-#{id}">.*?</table>}m]
      table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>(.*?)</tr>})
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
        .to eq(["Source", "Proposed", "Not kept", "Same plan as the original", "Wrong results",
                "Not better", "Ranked", "Stopped for another reason"])
      expect(rows(accountable, "rewrites").keys).to eq(["Transform rules", "The LLM", "You"])
    end

    # Task 20261004-69: the burndown's "refused on arrival" is only
    # llm-rewrites' and operator-rewrites' own rules, so this column, which
    # counts every proposal that wasn't stored, has a name of its own.
    it "says what the not kept column counts: every rewrite dropped before it was stored" do
      expect(accountable).to include(
        "A rewrite not kept is one QUAACK dropped before it was stored: it was over the limit (five from the LLM, " \
        "ten made by two transform rules in a row), assumed something QUAACK can't check or your data doesn't " \
        "hold, failed the checks on what goes in, didn't plan, returned different columns, or couldn't have its " \
        "clock pinned, or, from a transform rule, repeated another."
      )
      expect(accountable).not_to include("refused on arrival")
    end

    it "counts each source's rewrites by what became of them" do
      counted = rows(accountable, "rewrites")
      expect(counted["Transform rules"]).to eq(%w[3 2 0 0 0 1 0])
      expect(counted["The LLM"]).to eq(%w[8 2 1 3 1 0 1])
    end

    it "never counts a failed, tied, or unfinished rewrite as wrong or not better" do
      expect(rows(accountable, "rewrites")["You"].last(5)).to eq(%w[0 0 0 0 2])
    end

    # Task 20261012-2: a fuzz disproof proved the rewrite wrong.
    it "counts a rewrite a random small database proved wrong as wrong results" do
      wrong = rewrites + [fated(30, "fuzz_disproved", source: "operator", rule: "row_count")]
      expect(rows(render(payload.merge("rewrites" => wrong)), "rewrites")["You"].last(5)).to eq(%w[0 1 0 0 2])
    end

    # Task 20261012-3.
    it "counts a rewrite a small database QUAACK enumerated proved wrong as wrong results" do
      wrong = rewrites + [fated(30, "enumerate_disproved", source: "operator", rule: "value")]
      expect(rows(render(payload.merge("rewrites" => wrong)), "rewrites")["You"].last(5)).to eq(%w[0 1 0 0 2])
    end

    it "counts every fate that neither proved a rewrite wrong nor judged it not better as stopped for another reason" do
      others = %w[counterexamples_failed rewrite_test_untested production_timed_out production_not_compared
                  below_top_three measurement_timed_out]
      stopped = rewrites + others.each_with_index.map { |fate, i| fated(20 + i, fate, source: "operator") }
      counted = rows(render(payload.merge("rewrites" => stopped)), "rewrites")
      expect(counted["You"].last(5)).to eq(%w[0 0 0 0 8])
    end

    it "says not recorded, never zero, for proposals and refusals the burndown doesn't count" do
      expect(rows(accountable, "rewrites")["You"].first(2)).to eq(["not recorded", "not recorded"])
      expect(rows(html, "rewrites")["Transform rules"]).to eq(["not recorded", "not recorded", "0", "0",
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
          .to eq(["Source", "Proposed", "Already existed", "Planner ignored or couldn&#39;t try", "Built and measured",
                  "Not better", "Ranked"])
        expect(rows(html, "indexes").keys)
          .to eq(["From the query&#39;s text", "From the query&#39;s plan", "The LLM",
                  "All sources together"])
      end

      # Task 20261003-4: HypoPG's refusals count there too, and the planner
      # was never asked about those.
      it "says under the table that an index it couldn't try never reached the planner" do
        expect(section(html, "accountability")).to include(
          "<p class=\"note\">Planner ignored or couldn't try also counts the ideas QUAACK couldn't try, because " \
          "HypoPG, which it uses to try an index without building it, couldn't create them, or because it couldn't " \
          "write their definition. The planner was never " \
          "asked about those.</p>"
        )
      end

      it "says not recorded for every count by source that the payload doesn't carry" do
        missing = ["not recorded"] * 6
        expect(rows(html, "indexes").values.first(3)).to eq([missing, missing, missing])
      end

      it "counts what the payload does carry, for all sources together: built, ranked, and not" do
        expect(rows(html, "indexes")["All sources together"])
          .to eq(["not recorded", "not recorded", "not recorded", "2", "1", "1"])
      end

      # Task 20261004-80: the payload's index_sources counts, for each
      # source, the built indexes it proposed, and an index several sources
      # proposed counts under each.
      describe "built, not better, and ranked by source" do
        let(:index_sources) do
          { "generator_one" => { "built" => 1, "not_better" => 0, "ranked" => 1, "existed" => 3, "ignored" => 4 },
            "generator_two" => { "built" => 0, "not_better" => 0, "ranked" => 0, "existed" => 0, "ignored" => 5 },
            "llm" => { "built" => 2, "not_better" => 1, "ranked" => 1, "existed" => 0, "ignored" => 0 } }
        end
        let(:sourced) { render(payload.merge("index_sources" => index_sources)) }

        it "fills in each source's built, not better, and ranked from the payload's index sources" do
          counted = rows(sourced, "indexes")
          expect(counted["From the query&#39;s text"].last(3)).to eq(%w[1 0 1])
          expect(counted["From the query&#39;s plan"].last(3)).to eq(%w[0 0 0])
          expect(counted["The LLM"].last(3)).to eq(%w[2 1 1])
        end

        # Task 20261003-5: and each generator's already existing and planner
        # ignored candidates. The LLM's come from its rounds' burndown.
        it "fills in each generator's already existed and planner ignored from the payload's index sources" do
          counted = rows(sourced, "indexes")
          expect(counted["From the query&#39;s text"][1, 2]).to eq(%w[3 4])
          expect(counted["From the query&#39;s plan"][1, 2]).to eq(%w[0 5])
          expect(counted["The LLM"][1, 2]).to eq(rows(html, "indexes")["The LLM"][1, 2])
          expect(rows(html, "indexes")["From the query&#39;s text"][1, 2])
            .to eq(["not recorded", "not recorded"])
        end

        it "keeps all sources together's counts of each built index once" do
          expect(rows(sourced, "indexes")["All sources together"]).to eq(rows(html, "indexes")["All sources together"])
          expect(rows(sourced, "indexes")["All sources together"].last(3)).to eq(%w[2 1 1])
        end

        it "says under the table that an index several sources proposed counts in each of their rows" do
          note = "An index more than one source proposed counts in each of their rows, so the rows by source " \
                 "can add up to more than all sources together."
          expect(section(sourced, "accountability")).to include(note)
          expect(section(html, "accountability")).not_to include(note)
        end
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

        it "doesn't count an index whose only label was dropped when its results were compared" do
          expect(built("result_mismatch")).to eq(%w[2 0 1])
        end

        it "doesn't count an index whose only label timed out and was never judged" do
          payload["labels"][2].merge!("timed_out" => true, "measurements" => nil, "verdicts" => nil)
          expect(built(nil)).to eq(%w[2 0 1])
        end

        # Task 20261018-31: a skipped shared pairing never ran with it.
        it "counts an index whose every label was not better, less a shared pairing QUAACK skipped" do
          skipped = payload["labels"][2].merge("label" => "rewrite_1:shared:1", "timed_out" => false,
                                               "skipped" => true, "measurements" => nil, "verdicts" => nil)
          payload["labels"] << skipped
          expect(built("not_better")).to eq(%w[2 1 1])
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
            "An index counts as not better only if no candidate that ran with it beat the original query. A built " \
            "index " \
            "whose candidate beat the original query and still wasn't ranked (it tied with a smaller one, or three " \
            "others " \
            "did better), or whose candidate timed out, is counted only under built and measured."
          )
        end
      end

      # Task 20261004-77: a negative result's lists hold each index once,
      # but the proposals count every search's ideas, so the totals don't
      # come from them.
      it "doesn't count a negative result's declined and existing indices, which hold each index once" do
        expect(rows(render(negative_payload), "indexes")["All sources together"])
          .to eq(["not recorded", "not recorded", "not recorded", "2", "2", "0"])
      end

      # Task 20261004-77.
      describe "already existed and planner ignored, for all sources together" do
        before do
          stages.merge!(
            "index-from-query" => { "original" => rec(0, 3, added: { "generator_one" => 3 }) },
            "index-from-plan" => { "original" => rec(0, 4, added: { "generator_two" => 4 }) },
            "index-dedupe" => { "original" => rec(7, 4, dropped: { "covered_by_existing" => 2, "duplicate" => 1 }),
                                "rewrite_1" => rec(3, 2, dropped: { "covered_by_existing" => 1 }) },
            "index-test" => { "original" => rec(4, 2, dropped: { "never_used" => 1, "hypopg_refused" => 1 }),
                              "rewrite_1" => rec(2, 0, dropped: { "never_used" => 2 }) },
            "llm-index-ideas" => { "original" => rec(0, 1, added: { "llm" => 5 },
                                                           dropped: { "covered_by_existing" => 1, "duplicate" => 1,
                                                                      "never_used" => 1, "hypopg_refused" => 1 }) },
            "llm-index-refine" => { "original" => rec(0, 0, added: { "llm" => 1 }, dropped: { "never_used" => 1 }) }
          )
        end

        it "counts every search's ideas, the LLM's and the generators', as the proposals do" do
          counted = rows(accountable, "indexes")
          expect(counted["The LLM"].first(3)).to eq(%w[6 1 3])
          expect(counted["All sources together"].first(3)).to eq(%w[13 4 7])
        end

        def together
          rendered = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }))
          rows(rendered, "indexes")["All sources together"].first(3)
        end

        # Task 20260924-8: index-test counts an idea QUAACK couldn't write
        # as unrenderable, apart from what HypoPG refused.
        it "counts an idea QUAACK couldn't write as one it couldn't try" do
          stages["index-test"]["original"] = rec(5, 2, dropped: { "never_used" => 1, "hypopg_refused" => 1,
                                                                  "unrenderable" => 1 })
          stages["llm-index-ideas"]["original"] =
            rec(0, 1, added: { "llm" => 6 }, dropped: { "covered_by_existing" => 1, "duplicate" => 1, "never_used" => 1,
                                                        "hypopg_refused" => 1, "unrenderable" => 1 })
          counted = rows(accountable, "indexes")
          expect(counted["The LLM"][2]).to eq("4")
          expect(counted["All sources together"][2]).to eq("9")
        end

        it "says under the table what each column counts" do
          expect(section(html, "accountability")).to include(
            "Proposed, already existed, and planner ignored or couldn't try count the ideas of each search, for " \
            "the original query and for each rewrite, so an idea that came up in two searches counts twice. Built " \
            "and " \
            "measured, not better, and ranked count each index QUAACK built once."
          )
        end

        # Task 20261004-81 item 2: the definition's choice, said in the note.
        it "says under the table that planner ignored leaves out a later re-test's drops" do
          expect(section(html, "accountability")).to include(
            "Planner ignored or couldn't try counts only the first test of each idea. An index the planner " \
            "ignored or HypoPG refused when ranking tested it again isn't counted."
          )
        end

        it "says not recorded unless the generators' and the LLM's are both recorded" do
          stages.delete("index-dedupe")
          stages.delete("index-test")
          expect(together).to eq(["13", "not recorded", "not recorded"])
          stages.delete("llm-index-ideas")
          stages.delete("llm-index-refine")
          stages.merge!("index-dedupe" => { "original" => rec(3, 3) }, "index-test" => { "original" => rec(3, 3) })
          expect(together).to eq(["not recorded", "not recorded", "not recorded"])
        end
      end

      it "fills in each source's proposals, and the LLM's drops, once the burndown records them" do
        stages.merge!(
          "index-from-query" => { "original" => rec(0, 3, added: { "generator_one" => 3 }),
                                  "rewrite_1" => rec(0, 2, added: { "generator_one" => 2 }) },
          "index-from-plan" => { "original" => rec(0, 4, added: { "generator_two" => 4 }) },
          "llm-index-ideas" => { "original" => rec(0, 1, added: { "llm" => 6 },
                                                         dropped: { "covered_by_existing" => 2, "duplicate" => 1,
                                                                    "never_used" => 1, "hypopg_refused" => 1 }) },
          "llm-index-refine" => { "original" => rec(0, 0, added: { "llm" => 1 }, dropped: { "never_used" => 1 }) }
        )
        counted = rows(accountable, "indexes")
        expect(counted["From the query&#39;s text"]).to eq(["5"] + (["not recorded"] * 5))
        expect(counted["From the query&#39;s plan"]).to eq(["4"] + (["not recorded"] * 5))
        expect(counted["The LLM"]).to eq(["7", "2", "3", "not recorded", "not recorded", "not recorded"])
        expect(counted["All sources together"].first).to eq("16")
      end
    end
  end

  describe "the burndown" do
    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    # A stage's row opening, with the tooltip its stage's sentence gives it.
    def tr(name, of_rewrite: false)
      words = Quaack::Driver::Report::Words
      names = [words::INDEX_STAGES, words::REWRITE_STAGES, words::LATE_STAGES].reduce(:merge)
      prefix = "Index ideas for the rewrites: "
      of_rewrite ||= name.start_with?(prefix)
      stage = names.key(name) || names.key(name.delete_prefix(prefix).sub(/\A[a-z]/, &:upcase))
      tip = esc(Quaack::Driver::Report::StageSentences.for(stage, of_rewrite:))
      %(<tr title="#{tip}"><th scope="row">#{esc(name)}</th>)
    end

    def row(name, *cells)
      added, dropped, extra = cells.values_at(1, 2, 5)
      %(#{tr(name)}<td>#{added}</td><td>#{dropped}</td>) +
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
    let(:rewrite_index_table) { burndown_section[%r{<table id="burndown-rewrite-index">.*?</table>}m] }

    it "names the columns in words" do
      expect(index_table.scan(%r{<th scope="col"[^>]*>(.*?)</th>}).flatten)
        .to eq(["Stage", "Added", "Dropped", "Set aside for testing during ranking", "Went on", "Also counted"])
    end

    it "has no Came in column or cell, and a note under each table says which stages hold ideas back" do
      expect(index_table).not_to include("Came in")
      expect(index_table.scan(%r{<tr[^>]*><th scope="row">[^<]*</th>(.*?)</tr>}).first.first.scan("<td").size).to eq(5)
      %w[index rewrite rewrite-index].each do |id|
        note = burndown_section[%r{</table>\s*<p class="note" id="burndown-#{id}-held-back">(.*?)</p>}m, 1]
        expect(note).to start_with("Set aside for testing during ranking means")
        expect(note).to include("index-dedupe, and the LLM&#39;s rounds of index ideas, set aside GIN, GiST, and " \
                                "SP-GiST ideas")
        expect(note).to include("index-test sets aside").and include("the planner left unused")
        expect(note).not_to include("held back")
        expect(note).not_to include("real build")
      end
    end

    it "shows the original's index ideas stage by stage, in words, drops by reason" do
      expect(index_table).to include(row("Ideas from the query's text", 0, "from the query&#39;s text: 3", "none", 0,
                                         3, "none"))
      expect(index_table).to include(row("Removing duplicates and indices you already have", 4, "none",
                                         "the same as another idea: 1", 0, 3, "none"))
    end

    it "lists every stage, and says not recorded for one the run didn't count" do
      expect(index_table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>}).flatten)
        .to eq(["Ideas from the query&#39;s text", "Ideas from the query&#39;s plan",
                "Removing duplicates and indices you already have",
                "Asking the planner whether it would use each one", "Ideas from the LLM",
                "The LLM&#39;s second round of ideas", "Trying indices together"])
      expect(index_table).to include(tr("Ideas from the LLM") << '<td colspan="5" class="missing">' \
                                                                 "not recorded</td></tr>")
      expect(index_table.scan("not recorded").size).to eq(5)
    end

    it "says not recorded in the went-on cell of a stage that counted what came in but not what went on" do
      burndown["stages"]["index-test"] = { "original" => rec(3, nil, dropped: { "never_used" => 1 }).except("out") }
      expect(index_table).to include("#{tr("Asking the planner whether it would use each one")}" \
                                     "<td>none</td><td>never used by the planner: 1</td>" \
                                     '<td class="num">0</td><td class="missing">not recorded</td><td>none</td></tr>')
    end

    it "puts index-test's drops in words, an idea QUAACK couldn't write apart from what HypoPG refused" do
      burndown["stages"]["index-test"] = { "original" => rec(3, 1, dropped: { "hypopg_refused" => 1,
                                                                              "unrenderable" => 1 }) }
      expect(index_table).to include(row("Asking the planner whether it would use each one", 3, "none",
                                         "HypoPG couldn&#39;t create: 1; QUAACK couldn&#39;t write its " \
                                         "definition: 1", 0, 1, "none"))
    end

    it "shows the rewrite stages in words, in order, with their other counts" do
      expect(rewrite_table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>}).flatten)
        .to eq(["Transform rule rewrites", "Rewrites from the LLM", "Your own rewrites",
                "Checking what each rewrite assumes",
                "Checking each rewrite can run differently from the original query",
                "Testing on made-up edge-case data", "Testing on data the LLM wrote to break them",
                "Choosing indices for each rewrite", "Measuring on the real data and choosing"])
      expect(rewrite_index_table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>}).flatten)
        .to eq(["Index ideas for the rewrites: removing duplicates and indices you already have"])
      expect(rewrite_table).to include(row("Testing on made-up edge-case data", 2, "none",
                                           "wrong on made-up test data: 1", 0, 1,
                                           "conditions the test data never exercised: 2"))
      expect(rewrite_table).to include("#{tr("Rewrites from the LLM")}" \
                                       '<td colspan="5" class="missing">not recorded</td></tr>')
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
                                   "couldn&#39;t be compared on the real data: 1; no better than the original " \
                                   "query: 1; " \
                                   "timed out in every measurement run: 1; lost a tie on index size: 1; " \
                                   "outside the top three: 1", 0, 0,
                                   "compared on only part of the real data: 2"))
    end

    # Task 20261012-2: the fuzz search, between plan-pruning and rewrite-test.
    it "shows fuzz between plan-pruning and rewrite-test, with its drops by rule and its trials in words" do
      stages = { "plan-pruning" => { "rewrites" => rec(3, 2, dropped: { "same_plans" => 1 }) },
                 "fuzz" => { "rewrite_1" => rec(1, 0, dropped: { "row_count" => 1 }, extra: { "trials" => 40 }),
                             "rewrite_3" => rec(1, 0, dropped: { "query_failed" => 1 }, extra: { "trials" => 0 }),
                             "rewrite_2" => rec(1, 1, extra: { "trials" => 0, "untested" => 1 }) },
                 "rewrite-test" => { "rewrite_2" => rec(1, 1) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")

      names = table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>}).flatten
      expect(names.each_cons(3)).to include(["Checking each rewrite can run differently from the original query",
                                             "Testing on random small databases", "Testing on made-up edge-case data"])
      expect(table).to include(row("Testing on random small databases", 3, "none",
                                   "wrong on a random small database, where the row count differs: 1; wrong on a " \
                                   "random small database, where it failed and the original query ran: 1", 0, 1,
                                   "random small databases compared: 40; not tested by the random search, so " \
                                   "checked only on the LLM&#39;s test data and the real data: 1"))
    end

    # Task 20261012-15: a run with a spec setting that limits the searches
    # says so, so it can't pass for a normal one.
    it "words the marks of the spec settings that limit the searches" do
      extra = { "trials" => 40, "fuzz_trials_setting" => 1, "enumerate_worlds_setting" => 1 }
      stages = { "fuzz" => { "rewrite_1" => rec(1, 1, extra:), "rewrite_2" => rec(1, 1, extra:) },
                 "rewrite-test" => { "rewrite_1" => rec(2, 2) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")

      expect(table).to include(row("Testing on random small databases", 2, "none", "none", 0, 2,
                                   "random small databases compared: 80; searched with QUAACKS_FUZZ_TRIALS set, " \
                                   "a test setting that limits the random search: 2; searched with " \
                                   "QUAACKS_ENUMERATE_WORLDS set, a test setting that limits enumeration: 2"))
    end

    # Task 20261012-3: enumerate, between fuzz and rewrite-test.
    it "shows enumerate between fuzz and rewrite-test, with its drops by rule, worlds, and bounds in words" do
      stages = { "fuzz" => { "rewrite_1" => rec(1, 1, extra: { "trials" => 40 }),
                             "rewrite_2" => rec(1, 1, extra: { "trials" => 40 }),
                             "rewrite_3" => rec(1, 1, extra: { "trials" => 40 }),
                             "rewrite_4" => rec(1, 1, extra: { "trials" => 0, "untested" => 1 }) },
                 "enumerate" => { "rewrite_1" => rec(1, 0, dropped: { "value" => 1 }, extra: { "worlds" => 12 }),
                                  "rewrite_2" => rec(1, 1, extra: { "worlds" => 900, "bound_2" => 1 }),
                                  "rewrite_3" => rec(1, 1, extra: { "worlds" => 300, "bound_2" => 1 }),
                                  "rewrite_4" => rec(1, 1, extra: { "worlds" => 0, "untested" => 1 }) },
                 "rewrite-test" => { "rewrite_2" => rec(1, 1) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")

      names = table.scan(%r{<tr[^>]*><th scope="row">(.*?)</th>}).flatten
      expect(names.each_cons(3)).to include(["Testing on random small databases",
                                             "Testing on every small database up to a few rows",
                                             "Testing on made-up edge-case data"])
      expect(table).to include(row("Testing on every small database up to a few rows", 4, "none",
                                   "wrong on a small database QUAACK enumerated, where a value differs: 1", 0, 3,
                                   "small databases enumerated: 1,212; passed every database of up to 2 rows: 2; " \
                                   "not tested by enumeration: 1"))
    end

    # Task 20261012-4: the search replaced rewrite-test's scenarios, so a
    # run since records no rewrite-test, and the burndown leaves it out
    # rather than saying the run didn't count it.
    it "leaves rewrite-test out of a run since the search replaced it, in the table and the diagram" do
      stages = { "fuzz" => { "rewrite_1" => rec(1, 1, extra: { "trials" => 40 }) },
                 "enumerate" => { "rewrite_1" => rec(1, 1, extra: { "worlds" => 9 }) },
                 "counterexamples" => { "rewrite_1" => rec(1, 1) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include("Testing on every small database up to a few rows")
      expect(table).not_to include("edge-case")
    end

    # An older run's rewrite-test dropped a rewrite by the scenario that
    # disproved it; the report no longer names scenarios.
    it "words an older run's rewrite-test drops by scenario as wrong on made-up test data" do
      stages = { "rewrite-test" => { "rewrite_1" => rec(2, 0, dropped: { "s3" => 1, "s6" => 1 },
                                                              extra: { "vacuity_guard_retries" => 3 }) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include(row("Testing on made-up edge-case data", 2, "none",
                                   "wrong on made-up test data: 1; wrong on made-up test data: 1", 0, 0,
                                   "retries to make sure every condition mattered: 3"))
      expect(table).not_to include("duplicate join keys")
    end

    # A run stored before enumerate existed recorded fuzz but never enumerate.
    it "leaves enumerate out of a run from before it, rather than saying the run didn't count it" do
      stages = { "fuzz" => { "rewrite_1" => rec(1, 1, extra: { "trials" => 40 }) },
                 "rewrite-test" => { "rewrite_1" => rec(1, 1) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include("Testing on random small databases")
      expect(table).not_to include("every small database")
    end

    # A run stored before fuzz existed recorded rewrite-test but never fuzz.
    # A run that recorded neither still shows it as not recorded.
    it "leaves fuzz out of a run from before it, rather than saying the run didn't count it" do
      expect(rewrite_table).to include("Testing on made-up edge-case data")
      expect(rewrite_table).not_to include("random small databases")
      expect(rewrite_table).not_to include("every small database")
      stages = { "plan-pruning" => { "rewrites" => rec(1, 1) } }
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include("#{tr("Testing on random small databases")}" \
                               '<td colspan="5" class="missing">not recorded</td></tr>')
      expect(table).to include("#{tr("Testing on every small database up to a few rows")}" \
                               '<td colspan="5" class="missing">not recorded</td></tr>')
    end

    # Task 20261004-69: rewrite-test's never-tested reasons in the fates'
    # own words, and a counterexamples round that failed to run said so.
    it "says why rewrite-test never tested a rewrite, and which round failed to run, in words" do
      untested = { "s2" => 1, "complex_check" => 1, "statement_timeout" => 1, "query_failed" => 1, "failed" => 1,
                   "out_of_time" => 1 }
      stages = { "rewrite-test" => { "rewrite_1" => rec(6, 0, dropped: untested) },
                 "counterexamples" => { "rewrite_1" => rec(2, 0, dropped: { "round_1" => 1,
                                                                            "failed_in_round_3" => 1 }) } }
      html = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }))
      table = section(html, "burndown")

      tested = ["wrong on made-up test data: 1",
                "never tested, because a CHECK constraint on its tables is too complex for QUAACK to satisfy: 1",
                "never tested, because a statement timed out: 1",
                "never tested, because a statement failed on the test database: 1",
                "never tested, because a statement failed on the test database: 1",
                "never tested, because its test didn't finish within 5 minutes: 1"].join("; ")
      expect(table).to include(row("Testing on made-up edge-case data", 6, "none", esc(tested), 0, 0, "none"))
      expect(table).to include(row("Testing on data the LLM wrote to break them", 2, "none",
                                   "wrong in round 1: 1; failed to run in round 3: 1", 0, 0, "none"))
      expect(table).to include(esc("Dropped, never tested, because a CHECK constraint on its tables is too " \
                                   "complex for QUAACK to satisfy: 1"))
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
      expect(table).to include(row("Trying indices together", 4, "combinations tried: 4",
                                   "outside the top three: 1; a combination that left an index unused: 2; " \
                                   "a combination that wasn&#39;t the best: 1", 0, 4, "none"))
      stages["llm-index-refine"]["original"] = rec(0, 0, extra: { "no_ideas_tested" => 1, "fell_short" => 2 })
      table = section(render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })), "burndown")
      expect(table).to include(row("The LLM's second round of ideas", 0, "none", "none", 0, 0,
                                   "skipped, since the LLM had no ideas to test: 1; " \
                                   "ideas that fell short and went back to the LLM: 2"))
    end

    it "leaves a reason with a count of zero out, and names the ones that dropped something" do
      expect(rewrite_table).to include(row("Checking each rewrite can run differently from the original query", 2,
                                           "none", "planned the same as the original query: 1", 0, 1, "none"))
    end

    it "shows what each rule made" do
      expect(rewrite_table).to include(row("Transform rule rewrites", 0, "by the transform rule key_in_self_join: 2",
                                           "the same as another idea: 1", 0, 1, "none"))
    end

    # Task 20261018-1: only rewrites made by two rules in a row have a cap.
    it "says how many rewrites made by two rules in a row were over the limit of ten" do
      burndown["stages"]["rewrite-rules"]["rewrites"]["dropped"]["over_cap"] = 2
      expect(rewrite_table)
        .to include("the same as another idea: 1; made by two rules in a row, over the limit of ten: 2")
    end

    it "totals the rewrites' own index searches per stage" do
      expect(rewrite_index_table).to include(
        row("Index ideas for the rewrites: removing duplicates and indices you already have", 5, "none",
            "already covered by an index you have: 2", 1, 2, "none")
      )
    end

    # Task 20261017-8: the LLM searches only the rewrites that survived testing, but index-rank ranks every one.
    # rewrite_3's run stopped before its second round, which the LLM was asked about, so it isn't passed on.
    it "passes a rewrite's ideas through the LLM's rounds unchanged, and says so, when the LLM skipped that rewrite" do
      burndown["stages"].merge!(
        "index-test" => { "rewrite_1" => rec(1, 1), "rewrite_2" => rec(1, 1), "rewrite_3" => rec(1, 1) },
        "llm-index-ideas" => { "rewrite_1" => rec(1, 3, added: { "llm" => 3 }, dropped: { "never_used" => 1 }),
                               "rewrite_3" => rec(1, 1) },
        "llm-index-refine" => { "rewrite_1" => rec(3, 3, extra: { "nothing_fell_short" => 1 }) },
        "index-rank" => { "rewrite_1" => rec(3, 1), "rewrite_2" => rec(1, 1) }
      )
      passed = "ideas from rewrites the LLM wasn&#39;t asked about (ruled out or pruned before its rounds), " \
               "passed on unchanged: 1"
      expect(rewrite_index_table).to include(
        row("Index ideas for the rewrites: ideas from the LLM", 0, "from the LLM: 3", "never used by the planner: 1",
            0, 5, passed)
      )
      expect(rewrite_index_table).to include(
        row("Index ideas for the rewrites: the LLM's second round of ideas", 0, "none", "none", 0, 4,
            "skipped, since none of the LLM&#39;s ideas fell short: 1; #{passed}")
      )
      expect(index_table).not_to include("passed on unchanged")
    end

    it "says the rewrites' index searches weren't recorded when none was" do
      burndown["stages"].delete("index-dedupe")
      expect(rewrite_index_table).to include('<tr><th scope="row">Index ideas for the rewrites</th>' \
                                             '<td colspan="5" class="missing">not recorded</td></tr>')
    end

    it "says each LLM call in English, by what it was for" do
      calls = burndown_section[%r{<table id="llm-calls">.*?</table>}m]
      expect(calls.scan(%r{<tr[^>]*><th scope="row">(.*?)</th><td class="num">(.*?)</td></tr>}))
        .to eq([["Index suggestions for the original query", "2"],
                ["Revised index suggestions for the original query", "1"], ["Rewrite suggestions", "1"],
                ["Reading your own rewrites", "1"], ["Test data written to break the rewrites", "3"],
                ["Index suggestions for the rewrites", "4"], ["Revised index suggestions for the rewrites", "2"]])
    end

    # Task 20260926-42: provenance keeps the counts, so a resumed run
    # counts the calls made before it stopped too.
    it "says the LLM calls count those made before a resumed run stopped" do
      note = "<p class=\"note\">These are the calls the run made. If you resumed the run, they include " \
             "the calls made before it stopped.</p>"
      expect(burndown_section).to include("</table>\n#{note}")
      expect(section(html, "burndown")).to include(note)
    end

    it "says so when the driver counted no LLM call" do
      expect(section(html, "burndown")).to include('<p id="llm-calls">No LLM calls were counted in this run.</p>')
    end

    it "shows the work totals in words, and says not recorded for one the run didn't count" do
      totals = burndown_section[%r{<ul id="burndown-totals">.*?</ul>}m]
      expect(totals.scan(%r{<li>(.*?)</li>}).flatten)
        .to eq(["Plans tried with an index that wasn&#39;t built: 1,234", "Indices really built: not recorded",
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

    # Not rewrite-test, which a run since task 20261012-4 never records.
    it "says every stage wasn't recorded when the payload has no burndown" do
      expect(section(html, "burndown").scan('class="missing">not recorded').size).to eq(18)
    end
  end

  # Task 20261012-6: the Sankey diagrams replaced the funnels. What a funnel
  # said about a stage, the Sankey diagrams and the table say now.
  describe "the burndown's pictures and words" do
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
        "fuzz" => { "rewrites" => rec(5, 5, extra: { "trials" => 120 }) },
        "enumerate" => { "rewrites" => rec(5, 5, extra: { "worlds" => 900, "bound_2" => 5 }) },
        "rewrite-test" => { "rewrites" => rec(5, 4, dropped: { "s2" => 1 }) },
        "counterexamples" => { "rewrites" => rec(4, 3, dropped: { "round_1" => 1 }) },
        "rewrite-index-ideas" => { "rewrites" => rec(3, 3) },
        "measurement" => { "rewrites" => rec(3, 2, dropped: { "not_better" => 1 }) } }
    end

    let(:out) { render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })) }

    def table(id, html = out) = section(html, "burndown")[%r{<table id="burndown-#{id}">.*?</table>}m]

    # Every Sankey diagram of a table, together.
    def sankeys(id, html = out) = section(html, "burndown").scan(%r{<svg id="sankey-#{id}".*?</svg>}m).join

    # A stage's layer in its table's Sankey diagrams: its rect's attributes and hover.
    def layer(id, stage, html = out)
      words = Quaack::Driver::Report::Words
      name = ERB::Util.html_escape([words::INDEX_STAGES, words::REWRITE_STAGES, words::LATE_STAGES]
        .reduce(:merge).fetch(stage))
      found = sankeys(id, html).scan(%r{<rect ([^>]*)>(?:<title>(.*?)</title>)?}m).find do |attrs, _|
        attrs.include?(%(data-stage="#{esc(name)}"))
      end
      expect(found).not_to be_nil, "expected a layer for #{stage} in the #{id} Sankey diagrams"
      { "class" => found[0][/class="([^"]*)"/, 1], "title" => found[1].to_s }
    end

    it "reads a Sankey diagram, then the table, in each section, with no funnel and no note comparing them" do
      burndown = section(out, "burndown")
      %w[index rewrite rewrite-index].each do |id|
        expect(burndown.index(%(<svg id="sankey-#{id}"))).to be < burndown.index(%(<table id="burndown-#{id}">))
      end
      expect(burndown.scan(%r{<h4>(.*?)</h4>}).flatten)
        .to eq(["Diagram", "Table, with the exact numbers"] * 3)
      expect(out).not_to match(/funnel/i)
      expect(burndown).not_to include('class="note compare"')
      expect(burndown).not_to include("Both pictures")
    end

    # Task 20261019-1: "Sankey diagram" was a leftover from before; the reader needs no chart's name.
    it "never calls a diagram a Sankey diagram, and names each by what it shows" do
      expect(out).not_to match(/sankey diagram|<h4>sankey|as a sankey/i)
      expect(section(out, "burndown").scan(%r{<title id="sankey-[\w-]+-title">(.*?)</title>}).flatten).to eq(
        ["Index ideas for the original query", "Rewrites", "Index ideas for the rewrites"].map do |title|
          "#{title}, stage by stage: what came in, what dropped out and why, and what went on. " \
            "The table below has the exact numbers."
        end
      )
    end

    it "says once, below the diagrams, how an index idea differs from an index set and a rewrite from a candidate" do
      burndown = section(out, "burndown")
      note = burndown[%r{<p class="note" id="burndown-units">(.*?)</p>}m, 1]
      expect(note).to eq("An index idea is one proposed index, and an index set is the ideas QUAACK tries " \
                         "together, one alone or two or three combined; a rewrite is a rewritten version of your " \
                         "query, and a candidate is your original query or a rewrite, measured with one index set, " \
                         "or a rewrite measured with no new indices.")
      expect(burndown.index('id="burndown-units"')).to be > burndown.index('<table id="burndown-rewrite-index">')
      expect(burndown.index('id="burndown-units"')).to be < burndown.index("<h3>LLM calls</h3>")
      expect(burndown.scan('id="burndown-units"').size).to eq(1)
    end

    it "keeps no funnel drawing in the driver" do
      expect(Quaack::Driver::Report::View.new(payload, "run")).not_to respond_to(:funnel)
      expect(Quaack::Driver::Report.const_defined?(:Funnel, false)).to be(false)
      expect(Quaack::Driver::Report::StageStyle::COLORS).to include("index-dedupe" => "var(--st-violet)")
      expect(Quaack::Driver::Report::StageStyle::BLUE).to eq("var(--st-default)")
    end

    it "has one plain sentence for every stage the burndown can show" do
      words = Quaack::Driver::Report::Words
      shown = [words::INDEX_STAGES, words::REWRITE_STAGES, words::LATE_STAGES].flat_map(&:keys)
      shown.each do |stage|
        sentence = Quaack::Driver::Report::StageSentences::TABLE[stage]
        expect(sentence).to be_a(String).and(end_with(".")), "no sentence for the stage #{stage}"
        expect(sentence).not_to match(/your query|\n/i)
      end
      expect(Quaack::Driver::Report::StageSentences::TABLE.keys).to match_array(shown)
    end

    it "pins each stage's exact sentence" do
      expect(Quaack::Driver::Report::StageSentences::TABLE).to eq(
        "index-from-query" => "QUAACK reads the original query and suggests indices for the tables, columns, " \
                              "and conditions it uses.",
        "index-from-plan" => "QUAACK suggests indices from the plan the database made for the original query.",
        "index-dedupe" => "QUAACK drops ideas that repeat another idea or that an index you already have covers.",
        "index-test" => "QUAACK asks the planner whether it would use each idea, and drops the ones it wouldn't.",
        "llm-index-ideas" => "The LLM suggests indices that QUAACK's own search missed.",
        "llm-index-refine" => "If any index idea fell short, the LLM gets one chance to revise it.",
        "index-rank" => "QUAACK tries the indices together, adding one at a time while the cost keeps " \
                        "dropping, up to three. It doesn't try every combination: it pairs the best single " \
                        "index with each of the others, then tries triples the same way, so n ideas take about " \
                        "n - 1 pairs and up to n - 2 triples.",
        "rewrite-rules" => "The transform rules rewrite the query, and QUAACK drops rewrites that fail its checks.",
        "llm-rewrites" => "The LLM suggests rewrites of the original query, and QUAACK drops any that fail " \
                          "its checks or go over the limit of five.",
        "operator-rewrites" => "QUAACK asks the LLM what each rewrite you wrote assumes, checks those assumptions " \
                               "against the database, and warns about any it can't confirm.",
        "assumption-check" => "QUAACK checks each assumption a rewrite makes against the database's " \
                              "constraints and indices.",
        "plan-pruning" => "QUAACK plans each rewrite, and drops any that can't plan, return a different number or " \
                          "type of columns, or get the same plan as the original query, with or without indices.",
        "rewrite-test" => "QUAACK runs each rewrite on made-up data built to show where it differs from " \
                          "the original query.",
        "fuzz" => "QUAACK runs each rewrite and the original query on random small databases built around the " \
                  "query's own values, and drops any rewrite whose results differ.",
        "enumerate" => "QUAACK then runs each rewrite that's left and the original query on every database of up " \
                       "to a few rows over the query's own values, smallest first, for up to 30 seconds, and drops " \
                       "any rewrite whose results differ.",
        "counterexamples" => "The LLM writes data to try to break each rewrite that's left, for up to three rounds.",
        "rewrite-index-ideas" => "Each rewrite that's left gets its own index search, since it can need " \
                                 "different indices than the original query.",
        "measurement" => "QUAACK builds the indices, measures how many blocks each candidate reads on the real " \
                         "data, and chooses the best."
      )
    end

    it "says 'the rewrite' in the rewrites' index table, and 'the original query' in the original's" do
      tips = Quaack::Driver::Report::StageSentences::TABLE
      html = render(payload.merge("burndown" => { "stages" => stages.merge(
        "index-from-query" => { "original" => rec(0, 4), "rewrite_1" => rec(0, 2) }
      ), "totals" => {} }))
      original = tips.fetch("index-from-query")
      rewrote = original.sub("the original query", "the rewrite")
      expect(rewrote).not_to eq(original)
      expect(table("index", html)).to include(%(<tr title="#{esc(original)}">))
      expect(table("rewrite-index", html)).to include(%(<tr title="#{esc(rewrote)}">))
      expect(table("rewrite-index", html)).not_to include(esc(original))
    end

    it "says what each stage does in its Sankey hover and in its table row's tooltip" do
      words = Quaack::Driver::Report::Words
      { "index" => words::INDEX_STAGES, "rewrite" => words::REWRITE_STAGES.merge(words::LATE_STAGES) }
        .each do |id, names|
          names.each do |stage, name|
            sentence = ERB::Util.html_escape(Quaack::Driver::Report::StageSentences::TABLE.fetch(stage))
            expect(sankeys(id)).to match(%r{<title>[^<]*#{Regexp.escape(sentence)}[^<]*</title>}),
                                   "no Sankey hover for #{stage}"
            expect(table(id)).to include(%(<tr title="#{sentence}"><th scope="row">#{ERB::Util.html_escape(name)}</th>))
          end
        end
    end

    it "shows a stage the run didn't count as not recorded, never as zero, in the Sankey and the table" do
      name = esc(ERB::Util.html_escape(Quaack::Driver::Report::Words::INDEX_STAGES.fetch("index-test")))
      unknown = layer("index", "index-test")
      expect(unknown["class"]).to end_with(" unknown")
      expect(unknown["title"]).to start_with("#{name}: not recorded. " \
                                             "This run didn&#39;t count it, which doesn&#39;t mean none.")
      missing = '<td colspan="5" class="missing">not recorded</td>'
      expect(table("index")).to include(%(<th scope="row">#{name}</th>#{missing}))
    end

    it "shows a stage that counted what came in but not what went on, in the Sankey's hover and the table" do
      stages["index-test"] = { "original" => rec(3, 1, dropped: { "never_used" => 1 }).except("out") }
      partial = layer("index", "index-test")
      expect(partial["class"]).to end_with(" partial")
      expect(partial["title"]).to start_with("How many went on: not recorded. " \
                                             "This run didn&#39;t count it, which doesn&#39;t mean none.")
      expect(table("index")).to include("<td>never used by the planner: 1</td>" \
                                        '<td class="num">0</td><td class="missing">not recorded</td>')
      expect(sankeys("index")).to include("Dropped, never used by the planner: 1")
    end

    it "shows a stage that counted what went on but not what came in as not recorded in the Sankey" do
      stages["index-dedupe"]["original"] = rec(6, 3, dropped: { "duplicate" => 3 }).except("in")
      expect(layer("index", "index-dedupe")["class"]).to end_with(" unknown")
    end

    it "shows a stage with a negative count as not recorded in the Sankey, never as that count" do
      stages["index-dedupe"]["original"] = rec(-1, 3)
      stages["index-rank"]["original"] = rec(3, -2)
      expect(layer("index", "index-dedupe")["class"]).to end_with(" unknown")
      expect(sankeys("index").scan(/>([^<]*)</).join(" ")).not_to match(/-[12]\b/)
    end

    it "says in the Sankey and the table what a stage set aside, added, and dropped, by reason" do
      stages["index-dedupe"]["original"] = rec(6, 3, dropped: { "duplicate" => 2 }, set_aside: 1)
      index = sankeys("index")
      expect(index).to include("Set aside for testing during ranking: 1")
      expect(index).to include("Dropped, the same as another idea: 2")
      expect(sankeys("rewrite")).to include("From the LLM: 5")
      expect(table("index")).to include("<td>the same as another idea: 2</td><td class=\"num\">1</td>" \
                                        '<td class="num">3</td>')
    end

    it "escapes its words without setting marked SQL apart, since an SVG text can't hold code" do
      expect(Quaack::Driver::Report::StageStyle.text("on #{Quaack::Driver::Report::Format.sql_span("a < 1")}"))
        .to eq("on a &lt; 1")
    end

    it "keeps each table, with its exact numbers, under its Sankey diagrams" do
      tip = esc(Quaack::Driver::Report::StageSentences::TABLE.fetch("operator-rewrites"))
      expect(table("rewrite")).to include(%(<tr title="#{tip}"><th scope="row">Your own rewrites</th><td>))
    end
  end

  # Task 20261021-2: each of your own rewrites appears in the queries
  # section, kept or not; a refused one with its text and the reason.
  describe "your own rewrites in the queries section" do
    def own(index, rule, sql: "SELECT #{index}", outcome: "rejected", rewrite: nil)
      { "index" => index, "sql" => sql, "outcome" => outcome, "rule" => rule, "rewrite" => rewrite }
    end

    let(:queries) do
      own_rewrites = [own(1, "output_mismatch"), own(2, "unknown_name", sql: nil),
                      own(3, "a_rule_without_words"), own(4, nil, outcome: "accepted", rewrite: "rewrite_1")]
      section(render(payload.merge("own_rewrites" => own_rewrites)), "queries")
    end

    def article(index) = queries[%r{<article class="rewrite own-rewrite" id="own-rewrite-#{index}">.*?</article>}m]

    it "lists a refused one with its text and the reason in the report's words" do
      expect(article(1)).to include("<h3>Your own rewrite 1</h3>",
                                    "What became of it: QUAACK dropped it before testing it: it returned " \
                                    "different columns.", %(<pre class="sql"><code>SELECT 1</code></pre>))
    end

    it "gives a rule's fixed note when it has one, and says when its text was held back" do
      expect(article(2)).to include("A rewrite uses a function, type, collation, or operator",
                                    "QUAACK held back its text")
      expect(article(2)).not_to include(%(<pre class="sql">))
    end

    it "falls back to the inbound check's words for a rule without its own" do
      expect(article(3)).to include("it failed the checks on what goes in.")
    end

    it "lists a kept one as the stored rewrite it became, and no refused article for it" do
      expect(article(4)).to be_nil
      expect(queries).to include("Your own rewrite 4 is <a href=\"#rewrite-1\">")
    end

    it "lists none for a payload without own_rewrites" do
      expect(section(render(payload), "queries")).not_to include("own-rewrite")
    end
  end

  describe "the burndown Sankey diagrams" do
    sankey_module = Quaack::Driver::Report::Sankey
    layout_module = Quaack::Driver::Report::SankeyLayout

    def rec(inn, out, added: {}, dropped: {}, set_aside: 0, extra: {}) # rubocop:disable Metrics/ParameterLists
      { "in" => inn, "added" => added, "dropped" => dropped, "set_aside" => set_aside, "out" => out,
        "extra" => extra }
    end

    # The original query's flow of 20261010-20's screenshot: 6 ideas the planner used,
    # 8 after the LLM's first round, 9 after its second, 4 sets after ranking. The rewrites'
    # flow is 2, then 6, then 7.
    let(:stages) do
      { "index-from-query" => { "original" => rec(0, 7, added: { "generator_one" => 7 }),
                                "rewrite_1" => rec(0, 2, added: { "generator_one" => 2 }) },
        "index-from-plan" => { "original" => rec(7, 9, added: { "generator_two" => 2 }) },
        "index-dedupe" => { "original" => rec(9, 8, dropped: { "duplicate" => 1 }),
                            "rewrite_1" => rec(2, 1, dropped: { "duplicate" => 1 }) },
        "index-test" => { "original" => rec(8, 6, dropped: { "never_used" => 1 }, set_aside: 1) },
        "llm-index-ideas" => { "original" => rec(6, 8, added: { "llm" => 5 },
                                                       dropped: { "inbound_check" => 2, "duplicate" => 1 }) },
        "llm-index-refine" => { "original" => rec(8, 9, added: { "llm" => 2 }, dropped: { "failed_checks" => 1 }) },
        "index-rank" => { "original" => rec(9, 4, added: { "combinations" => 6 },
                                                  dropped: { "never_used" => 2, "below_top_three" => 3,
                                                             "combination_unused_index" => 1,
                                                             "combination_not_chosen" => 5 }),
                          "rewrite_1" => rec(1, 1, added: { "combinations" => 1 },
                                                   dropped: { "combination_not_chosen" => 1 }) },
        "rewrite-rules" => { "rewrites" => rec(0, 2, added: { "key_in_self_join" => 3, "or_to_union" => 1 },
                                                     dropped: { "duplicate" => 2 }) },
        "llm-rewrites" => { "rewrites" => rec(2, 6, added: { "llm" => 5 }, dropped: { "inbound_check" => 1 }) },
        "operator-rewrites" => { "rewrites" => rec(6, 7, added: { "operator" => 1 }) },
        "assumption-check" => { "rewrites" => rec(7, 6, dropped: { "unmet_assumption" => 1 }) },
        "plan-pruning" => { "rewrites" => rec(6, 5, dropped: { "same_plans" => 1 }) },
        "fuzz" => { "rewrites" => rec(5, 5, extra: { "trials" => 900 }) },
        "enumerate" => { "rewrites" => rec(5, 5, extra: { "worlds" => 900, "bound_2" => 5 }) },
        "rewrite-test" => { "rewrites" => rec(5, 4, dropped: { "s2" => 1 }) },
        "counterexamples" => { "rewrites" => rec(4, 3, dropped: { "round_1" => 1 }) },
        "rewrite-index-ideas" => { "rewrites" => rec(3, 3) },
        "measurement" => { "rewrites" => rec(3, 2, dropped: { "not_better" => 1 }) } }
    end

    let(:out) { render(payload.merge("burndown" => { "stages" => stages, "totals" => {} })) }

    def sankey(id, html = out)
      svg = section(html, "burndown")[%r{<svg id="sankey-#{id}".*?</svg>}m]
      expect(svg).not_to be_nil, %(expected the burndown section to hold <svg id="sankey-#{id}">)
      svg
    end

    # A stage's name, as a diagram's nodes carry it in data-stage (never the stage's own key).
    def named(stage)
      words = Quaack::Driver::Report::Words
      esc(ERB::Util.html_escape([words::INDEX_STAGES, words::REWRITE_STAGES,
                                 words::LATE_STAGES].reduce(:merge).fetch(stage)))
    end

    def attributes(tag) = tag.scan(/([\w-]+)="([^"]*)"/).to_h

    def nodes(svg, kind = nil)
      svg.scan(%r{<rect ([^>]*)>(?:<title>(.*?)</title>)?}m)
         .map { |attrs, title| attributes(attrs).merge("title" => title) }
         .select { kind.nil? || it["class"].split.include?(kind) }
    end

    def ribbons(svg, kind = nil)
      svg.scan(%r{<path ([^>]*)>(?:<title>(.*?)</title>)?}m)
         .map { |attrs, title| attributes(attrs).merge("title" => title) }
         .select { it["class"].start_with?("ribbon") && (kind.nil? || it["class"].split.include?(kind)) }
    end

    def texts(svg)
      svg.scan(%r{<text class="([^"]*)" x="([\d.]+)" y="([\d.]+)"(?: text-anchor="(\w+)")?>(.*?)</text>}m)
         .map { |kind, x, y, anchor, text| { kind:, x: x.to_f, y: y.to_f, anchor:, text: } }
    end

    # What a diagram's layers say, top to bottom.
    def layers(id, html = out)
      texts(sankey(id, html)).select { it[:kind] == "layer" }.map { it[:text] }
    end

    def stage_nodes(svg) = nodes(svg, "layer")

    # A layer's label, for the layer rect: the text on the layer's row.
    def layer_named(svg, words) = stage_nodes(svg).find { |node| layer_text(svg, node) == words }

    def layer_text(svg, node)
      texts(svg).find { it[:kind] == "layer" && (it[:y] - node["y"].to_f - 15).abs < 0.01 }&.fetch(:text)
    end

    # A node's id's stage count, and the flows in and out of it, from the ribbons.
    def inflow(svg, id) = ribbons(svg).select { it["data-to"] == id }.sum { it["data-count"].to_i }

    def outflow(svg, id) = ribbons(svg).select { it["data-from"] == id }.sum { it["data-count"].to_i }

    def numbers(path) = path.scan(/-?\d+(?:\.\d+)?/).map(&:to_f)

    def steps(id, html = out) = texts(sankey(id, html)).select { it[:kind] == "step" }.map { it[:text] }

    # DESIGN.md: each stage has its own color from a fixed palette, so it keeps its color
    # in every diagram. [diagram, stage, fill] for every stage's layer (merge or after), named
    # by its first stage, whatever its fill.
    def painted_layers(html)
      key_of = stage_keys_by_name
      section(html, "burndown").scan(%r{<svg id="sankey-.*?</svg>}m).flat_map do |svg|
        stage_nodes(svg).select { stage_layer?(it) }.map do |node|
          [svg[/id="sankey-([\w-]+)"/, 1], key_of.fetch(node["data-stage"].split("; ").first),
           node["style"].to_s[/fill: ([^;"]+)/, 1]]
        end
      end
    end

    # A stage's own layer, not the layer a diagram starts from or the set-aside one.
    def stage_layer?(node) = node["class"].split.intersect?(%w[merge after])

    # Each stage's key, by the name its layers carry, including the rewrites' index searches.
    def stage_keys_by_name
      words = Quaack::Driver::Report::Words
      names = [words::INDEX_STAGES, words::REWRITE_STAGES, words::LATE_STAGES].reduce(:merge)
      searches = words::INDEX_STAGES.to_h do |stage, name|
        [esc(ERB::Util.html_escape("Index ideas for the rewrites: #{words.lower(name)}")), stage]
      end
      names.keys.to_h { [named(it), it] }.merge(searches)
    end

    it "paints each stage's layers in the stage's own palette color, the same in every diagram" do
      colors = Quaack::Driver::Report::StageStyle::COLORS
      painted = painted_layers(out)
      expect(painted.reject { |_, stage, fill| fill == colors.fetch(stage) }).to eq([])
      # Every stage the fixture records, but index-from-plan, which joins index-from-query's layer.
      expect(painted.map { it[1] }.uniq.sort).to eq((colors.keys - ["index-from-plan"]).sort)
      dedupe = painted.select { it[1] == "index-dedupe" }
      expect(dedupe.map(&:first).uniq).to eq(%w[index rewrite-index])
      expect(dedupe.map(&:last).uniq).to eq(["var(--st-violet)"])
      expect(painted.select { it[1] == "rewrite-test" }.map(&:last).uniq).to eq(["var(--st-green)"])
      expect(painted.select { it[1] == "fuzz" }.map(&:last).uniq).to eq(["var(--st-indigo)"])
      expect(painted.select { it[1] == "enumerate" }.map(&:last).uniq).to eq(["var(--st-slate)"])
      expect(painted.map { it[1] }.uniq.map { colors[it] }.uniq.size).to be >= 7
    end

    it "draws one layer per state, in order: a stage that adds and drops is a merge layer and the layer after it" do
      expect(layers("index")).to eq(
        ["Mechanical index ideas: 9", "After removing duplicates and indices you already have: 8",
         "After testing for planner utility: 6", "Combined with new ideas from the LLM: 11",
         "After testing the LLM&#39;s ideas: 8", "Combined with the LLM&#39;s second round of ideas: 10",
         "After the LLM&#39;s second round of ideas: 9", "Index sets to try: 15",
         "After trying indices together: 4", "Set aside for testing during ranking: 1"]
      )
      expect(layers("rewrite")).to eq(
        ["Rewrites from the transform rules: 4", "After removing duplicate rule rewrites: 2",
         "Combined with rewrites from the LLM: 7", "After checking the LLM&#39;s rewrites: 6",
         "Combined with your own rewrites: 7", "After checking what each rewrite assumes: 6",
         "After checking each rewrite runs differently: 5", "After testing on random small databases: 5",
         "After testing on every small database up to a few rows: 5", "After testing on made-up edge-case data: 4",
         "After testing on data the LLM wrote to break them: 3",
         "Candidates after choosing indices for each rewrite: 3", "Candidates after measuring on the real data: 2"]
      )
      %w[index rewrite rewrite-index].each do |id|
        svg = sankey(id)
        expect(layers(id).uniq).to eq(layers(id))
        expect(stage_nodes(svg).size).to eq(layers(id).size)
        expect(svg).not_to include("Went on")
        expect(nodes(svg, "end")).to eq([])
      end
    end

    # Task 20261017-8: rewrite_2 was pruned, so only rewrite_1 got the LLM's rounds, but both were ranked.
    it "carries into the rewrites' ranking what the diagram above ends with, when the LLM skipped a rewrite" do
      searched = { "index-from-query" => { "rewrite_1" => rec(0, 3, added: { "generator_one" => 3 }),
                                           "rewrite_2" => rec(0, 2, added: { "generator_one" => 2 }) },
                   "index-dedupe" => { "rewrite_1" => rec(3, 3), "rewrite_2" => rec(2, 2) },
                   "index-test" => { "rewrite_1" => rec(3, 2, dropped: { "never_used" => 1 }),
                                     "rewrite_2" => rec(2, 1, dropped: { "never_used" => 1 }) },
                   "llm-index-ideas" => { "rewrite_1" => rec(2, 4, added: { "llm" => 3 },
                                                                   dropped: { "never_used" => 1 }) },
                   "llm-index-refine" => { "rewrite_1" => rec(4, 5, added: { "llm" => 2 },
                                                                    dropped: { "never_used" => 1 }) },
                   "index-rank" => { "rewrite_1" => rec(5, 1, added: { "combinations" => 4 },
                                                              dropped: { "below_top_three" => 4,
                                                                         "combination_not_chosen" => 4 }),
                                     "rewrite_2" => rec(1, 1) } }
      html = render(payload.merge("burndown" => { "stages" => searched, "totals" => {} }))
      expect(layers("rewrite-index", html)).to eq(
        ["Index ideas from the query&#39;s text: 5", "After removing duplicates and indices you already have: 5",
         "After testing for planner utility: 3", "Combined with new ideas from the LLM: 6",
         "After testing the LLM&#39;s ideas: 5", "Combined with the LLM&#39;s second round of ideas: 7",
         "After the LLM&#39;s second round of ideas: 6", "Index sets to try: 10", "After trying indices together: 2"]
      )
      svg = sankey("rewrite-index", html)
      ["After testing the LLM&#39;s ideas: 5", "After the LLM&#39;s second round of ideas: 6"].each do |words|
        expect(layer_named(svg, words)["title"])
          .to include("1 idea from rewrites the LLM wasn&#39;t asked about went on unchanged.")
      end
    end

    it "draws each layer as wide as its state: in plus added for a merge layer, what went on for the next" do
      svg = sankey("index")
      scale = sankey_module::SPINE_MAX / 15.0
      merge = layer_named(svg, "Combined with new ideas from the LLM: 11")
      after = layer_named(svg, "After testing the LLM&#39;s ideas: 8")
      expect(merge["width"].to_f).to be_within(0.05).of(scale * 11)
      expect(after["width"].to_f).to be_within(0.05).of(scale * 8)
      expect([merge["data-count"], after["data-count"]]).to eq(%w[11 8])
      expect(inflow(svg, merge["data-id"])).to eq(11)
      expect(inflow(svg, after["data-id"])).to eq(8)
      expect(outflow(svg, merge["data-id"])).to eq(11)
      carry = ribbons(svg, "carry").find { it["data-to"] == merge["data-id"] }
      expect(carry["data-count"]).to eq("6")
      expect(numbers(carry["d"])[6]).to be_within(0.05).of(merge["x"].to_f + (scale * 5))
      lands = ribbons(svg, "source").find { it["data-to"] == merge["data-id"] }
      expect(numbers(lands["d"])[6]).to be_within(0.05).of(merge["x"].to_f)
    end

    it "labels each transition with its step, and sends each drop off to the right with its own label" do
      names = Quaack::Driver::Report::Words::INDEX_STAGES
      expect(steps("index")).to eq(names.values_at("index-dedupe", "index-test", "llm-index-ideas",
                                                   "llm-index-refine", "index-rank").map { esc(it) })
      expect(steps("rewrite-index").last).to eq(names["index-rank"])
      svg = sankey("index")
      step = texts(svg).find { it[:text] == names["index-test"] }
      above = layer_named(svg, "After removing duplicates and indices you already have: 8")
      below = layer_named(svg, "After testing for planner utility: 6")
      expect(step[:y]).to be > above["y"].to_f + 22
      expect(step[:y]).to be < below["y"].to_f
      drop = nodes(svg, "drop").find { it["data-stage"] == esc(names["index-test"]) }
      expect(drop["y"].to_f).to be > step[:y]
      expect(drop["y"].to_f).to be < below["y"].to_f
      expect(nodes(svg, "drop").map { it["x"].to_f }).to all(be > layout_module::LEFT + sankey_module::SPINE_MAX)
      expect(texts(svg).select { it[:kind] == "flow" }.map { it[:text] })
        .to include("Dropped, never used by the planner: 1", "Dropped, the same as another idea: 1")
    end

    it "lays a layer's bottom edge out as what was set aside, then what carried on, then the drops, side by side" do
      svg = sankey("index")
      from = layer_named(svg, "After removing duplicates and indices you already have: 8")
      carry = numbers(ribbons(svg, "carry").find { it["data-from"] == from["data-id"] }["d"])
      held = numbers(ribbons(svg, "held").first["d"])
      drop = numbers(ribbons(svg, "drop").find { it["data-from"] == from["data-id"] }["d"])
      expect(held[0]).to be_within(0.01).of(from["x"].to_f)
      expect(carry[0]).to be_within(0.01).of(held[-2])
      expect(drop[0]).to be_within(0.01).of(carry[-2])
      expect(drop[-2]).to be <= from["x"].to_f + from["width"].to_f + 0.01
    end

    it "spreads the first layer's sources across the whole picture, and keeps later sources in lanes on the left" do
      svg = sankey("rewrite")
      first = stage_nodes(svg).first
      spread = nodes(svg, "source").select { it["data-id"].start_with?("#{first["data-id"]}-in") }
      expect(spread.map { it["data-count"] }).to eq(%w[3 1])
      expect(spread.first["x"].to_f).to be < 20
      expect(spread.last["x"].to_f).to be > layout_module::LEFT
      labels = texts(svg).select { it[:kind] == "source" }
      expect(labels.first(2).map { it[:text] }).to eq(["By the transform rule key_in_self_join: 3",
                                                       "By the transform rule or_to_union: 1"])
      expect(labels.first(2).map { it[:y] }.uniq.size).to eq(1)
      later = nodes(svg, "source") - spread
      expect(later.map { it["data-count"] }).to eq(%w[5 1])
      expect(later.map { it["x"].to_f + it["width"].to_f }).to all(be < layout_module::LEFT)
      combos = nodes(sankey("index"), "source").select { it["data-stage"] == named("index-rank") }
      expect(combos.size).to eq(1)
      expect(combos.map { it["x"].to_f + it["width"].to_f }).to all(be < layout_module::LEFT)
    end

    it "draws what a stage set aside as a transition into its own layer at the bottom left" do
      svg = sankey("index")
      held = nodes(svg, "held").find { it["class"].split.include?("layer") }
      expect(held["data-count"]).to eq("1")
      expect(held["x"].to_f + held["width"].to_f).to be < layout_module::LEFT
      expect(held["y"].to_f).to be > stage_nodes(svg).reject { it == held }.map { it["y"].to_f }.max
      ribbon = ribbons(svg, "held").first
      from = layer_named(svg, "After removing duplicates and indices you already have: 8")
      expect([ribbon["data-from"], ribbon["data-to"],
              ribbon["data-count"]]).to eq([from["data-id"], held["data-id"], "1"])
      expect(svg).not_to include("Held back")
    end

    it "shows every source a unit has, with a zero when it added nothing" do
      stages["llm-index-refine"] = { "original" => rec(8, 8, extra: { "nothing_fell_short" => 1 }) }
      stages["operator-rewrites"] = { "rewrites" => rec(6, 6) }
      svg = sankey("index")
      zero = nodes(svg, "source").find { it["data-stage"] == named("llm-index-refine") }
      expect(zero["data-count"]).to eq("0")
      expect(zero["width"].to_f).to be_within(0.01).of(layout_module::ZERO_BOX)
      expect(zero["style"]).to eq("fill: none; stroke: var(--sk-source)")
      expect(texts(svg).map { it[:text] }).to include("From the LLM: 0")
      empty, full = ribbons(svg).partition { it["class"].split.include?("zero") }
      expect(empty.map { [it["data-from"], it["data-count"], it["style"]] })
        .to eq([[zero["data-id"], "0", "fill: none; stroke: var(--sk-source)"]])
      expect(full.map { it["data-count"].to_i }).to all(be_positive)
      expect(layers("index")).to include("Combined with the LLM&#39;s second round of ideas: 8")
      rewrite = sankey("rewrite")
      expect(texts(rewrite).map { it[:text] }).to include("From you: 0")
      expect(nodes(rewrite, "source").find { it["data-stage"] == named("operator-rewrites") }["data-count"]).to eq("0")
    end

    it "draws a run with no rewrites at all as zero sources and zero layers, never an empty stack" do
      Quaack::Driver::Report::Words::REWRITE_STAGES.each_key { stages[it] = { "rewrites" => rec(0, 0) } }
      %w[assumption-check plan-pruning rewrite-test counterexamples].each { stages[it] = { "rewrites" => rec(0, 0) } }
      words = texts(sankey("rewrite")).map { it[:text] }
      expect(words).to include("From the transform rules: 0", "From the LLM: 0", "From you: 0")
      expect(words).to include("Rewrites from the transform rules: 0")
    end

    # Task 20261016-12: with no rewrites of your own, operator-rewrites never runs, so the
    # enclave records nothing for it. The driver knows you gave none (own_rewrites: 0), so
    # it shows the stage as adding nothing to what the LLM's rewrites left.
    describe "a run where you gave no rewrites of your own" do
      let(:none) do
        stages.delete("operator-rewrites")
        render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }), own_rewrites: 0)
      end

      it "merges an empty 'From you: 0' box into a layer as wide as the one above, with no grey box" do
        svg = sankey("rewrite", none)
        names = layers("rewrite", none)
        above = names.index("After checking the LLM&#39;s rewrites: 6")
        expect(names[above + 1]).to eq("Combined with your own rewrites: 6")
        widths = names[above, 2].map { layer_named(svg, it)["width"] }
        expect(widths.uniq.size).to eq(1), "expected the two layers as wide, got #{widths}"
        expect(svg).not_to include("not recorded")
        expect(nodes(svg).select { it["class"].include?("unknown") }).to eq([])
        expect(ribbons(svg).select { it["class"].include?("unknown") }).to eq([])
      end

      it "draws 'From you' as an empty box whose empty ribbon merges into that layer" do
        svg = sankey("rewrite", none)
        mine = nodes(svg, "source").find { it["data-stage"] == named("operator-rewrites") }
        expect(mine).not_to be_nil, "expected a source for your own rewrites"
        expect([mine["data-count"], mine["class"]]).to eq(["0", "node source zero"])
        expect(texts(svg).map { it[:text] }).to include("From you: 0")
        into = layer_named(svg, "Combined with your own rewrites: 6")
        flow = ribbons(svg, "source").find { it["data-from"] == mine["data-id"] }
        expect(flow).not_to be_nil, "expected an empty ribbon from #{mine["data-id"]}"
        expect([flow["class"], flow["data-to"], flow["data-count"]]).to eq(["ribbon source zero", into["data-id"], "0"])
        middle = mine["x"].to_f + (mine["width"].to_f / 2)
        expect([numbers(flow["d"])[0], numbers(flow["d"])[-2]]).to eq([middle, middle])
      end

      it "counts the stage in the table as adding none and sending on what the LLM's rewrites left" do
        row = section(none, "burndown")[%r{<th scope="row">Your own rewrites</th>.*?</tr>}m]
        expect(row).to eq('<th scope="row">Your own rewrites</th><td>none</td><td>none</td>' \
                          '<td class="num">0</td><td class="num">6</td><td>none</td></tr>')
      end

      it "still says not recorded when the driver doesn't say, or says you gave some" do
        stages.delete("operator-rewrites")
        [nil, 2].each do |own|
          html = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }), own_rewrites: own)
          expect(layers("rewrite", html)).to include("Combined with your own rewrites: not recorded")
        end
      end

      it "carries what the transform rules sent on if the LLM's rewrites weren't recorded, else not recorded" do
        stages.delete("operator-rewrites")
        stages.delete("llm-rewrites")
        html = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }), own_rewrites: 0)
        expect(layers("rewrite", html)).to include("Combined with your own rewrites: 2")
        stages.delete("rewrite-rules")
        html = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }), own_rewrites: 0)
        expect(layers("rewrite", html)).to include("Combined with your own rewrites: not recorded")
        expect(section(html, "burndown"))
          .to include('<th scope="row">Your own rewrites</th><td colspan="5" class="missing">not recorded</td>')
      end

      it "leaves a run with your own rewrites recorded as it was" do
        html = render(payload.merge("burndown" => { "stages" => stages, "totals" => {} }), own_rewrites: 0)
        expect(section(html, "burndown")).to eq(section(out, "burndown"))
        expect(layers("rewrite", html)).to include("Combined with your own rewrites: 7")
      end
    end

    it "keeps a layer's flows whole: what came into it is its count, and what leaves is the same" do
      %w[index rewrite rewrite-index].each do |id|
        svg = sankey(id)
        stage_nodes(svg).each do |node|
          next if node["class"].include?("unknown") || node["class"].include?("start")

          expect(inflow(svg, node["data-id"])).to eq(node["data-count"].to_i), "#{id} #{node["data-id"]}: in"
          leaves = outflow(svg, node["data-id"])
          expect(leaves).to eq(node["data-count"].to_i), "#{id} #{node["data-id"]}: out" if leaves.positive?
        end
      end
    end

    # Task 20261018-15: one diagram per table, with a dashed line where the unit changes.
    def divider(svg) = svg[/<line class="unit-divider" ([^>]*)>/, 1]&.scan(/([\w-]+)="([^"]*)"/).to_h

    it "flows the last layer above the unit change straight into the first below it, with no hand-off" do
      svg = sankey("index")
      above = layer_named(svg, "After the LLM&#39;s second round of ideas: 9")
      below = layer_named(svg, "Index sets to try: 15")
      carry = ribbons(svg, "carry").find { it["data-to"] == below["data-id"] }
      expect([carry["data-from"], carry["data-count"]]).to eq([above["data-id"], "9"])
      expect(nodes(svg, "start")).to eq([])
      expect(svg).not_to include("diagram above")
      expect(svg).not_to include("diagram below")
      combos = nodes(svg, "source").find { it["data-stage"] == named("index-rank") }
      expect(combos["data-count"]).to eq("6")
      expect(below["width"].to_f).to be > above["width"].to_f
    end

    it "draws a dashed line across the diagram where the unit changes, labelled at the right above and below" do
      { "index" => ["After the LLM&#39;s second round of ideas: 9", "Index sets to try: 15", "ideas", "sets"],
        "rewrite" => ["After testing on data the LLM wrote to break them: 3",
                      "Candidates after choosing indices for each rewrite: 3", "rewrites", "candidates"] }
        .each do |id, (up, down, over, under)|
          svg = sankey(id)
          line = divider(svg)
          expect(line).not_to be_nil, "expected a unit divider in #{id}"
          expect([line["x1"], line["x2"], line["y1"] == line["y2"]]).to eq(["0", "1040", true])
          expect(line["style"]).to eq("stroke: var(--sk-divider)")
          expect(line["stroke-dasharray"]).to be_truthy
          y = line["y1"].to_f
          expect(y).to be > layer_named(svg, up)["y"].to_f + 22
          expect(y).to be < layer_named(svg, down)["y"].to_f
          labels = texts(svg).select { it[:kind] == "unit" }
          expect(labels.map { it[:text] }).to eq(["Above the line: #{over}", "Below the line: #{under}"])
          expect(labels.map { it[:anchor] }.uniq).to eq(["end"])
          expect(labels[0][:y]).to be < y
          expect(labels[1][:y] - 11).to be > y
        end
      expect(section(out, "burndown")).not_to include("Unit: ")
    end

    it "never joins stages that only add across the line, since their units differ" do
      stages["llm-index-refine"] = { "original" => rec(8, 10, added: { "llm" => 2 }) }
      stages["index-rank"] = { "original" => rec(10, 16, added: { "combinations" => 6 }) }
      expect(layers("index")).to include("Combined with the LLM&#39;s second round of ideas: 10",
                                         "Index sets to try: 16")
      expect(divider(sankey("index"))).not_to be_nil
    end

    it "explains why the ranking tried as many combinations as it did, in a note under the diagram and its hover" do
      burndown = section(out, "burndown")
      note = burndown[%r{</svg>\n<p class="note" id="sankey-index-note">(.*?)</p>}m, 1]
      expect(note).to include("best single").and include("pairs").and include("triples")
      expect(note).to include("doesn&#39;t try every combination")
      rewrites = burndown[%r{</svg>\n<p class="note" id="sankey-rewrite-index-note">(.*?)</p>}m, 1]
      expect(rewrites).to include("across 1 rewrite: 1 for Rewrite")
      expect(burndown).not_to include(%(id="sankey-rewrite-note"))
      tip = Quaack::Driver::Report::StageSentences.for("index-rank")
      expect(tip).to include("pairs").and include("triples")
      expect(sankey("index")).to include(esc(tip))
      summed = Quaack::Driver::Report::StageSentences.for("index-rank", of_rewrite: true)
      expect(summed).to end_with("the counts here add up every rewrite&#39;s.".gsub("&#39;", "'"))
      searched = sankey("rewrite-index")
      ranked = stage_nodes(searched).find { layer_text(searched, it).to_s.start_with?("Index sets to try") }
      expect(ranked["title"]).to include(esc(summed)).and include("1 for Rewrite")
      expect(sankey("index")).not_to include("add up every rewrite")
    end

    it "draws widths on one scale for the whole diagram, above and below the line, against its widest layer" do
      svg = sankey("index")
      scale = sankey_module::SPINE_MAX / 15.0
      widest = stage_nodes(svg).map { it["width"].to_f }.max
      expect(widest).to be_within(0.05).of(sankey_module::SPINE_MAX)
      sink = nodes(svg, "drop").find { it["data-count"] == "2" }
      expect(sink["height"].to_f).to be_within(0.05).of(scale * 2)
      expect(layer_named(svg, "After testing for planner utility: 6")["width"].to_f).to be_within(0.05).of(scale * 6)
      expect(layer_named(svg, "After trying indices together: 4")["width"].to_f).to be_within(0.05).of(scale * 4)
    end

    it "tapers a carry whose two ends don't join up, so a mismatch shows in the picture as well as the table" do
      stages["index-test"] = { "original" => rec(7, 5, dropped: { "never_used" => 2 }) }
      svg = sankey("index")
      from = layer_named(svg, "After removing duplicates and indices you already have: 8")
      carry = ribbons(svg, "carry").find { it["data-from"] == from["data-id"] }
      scale = sankey_module::SPINE_MAX / 15.0
      nums = numbers(carry["d"])
      expect(nums[-2] - nums[0]).to be_within(0.05).of(scale * 6)
      expect(nums[8] - nums[6]).to be_within(0.05).of(scale * 5)
    end

    it "orders the sinks' ribbons so none cross: the top sink leaves the layer's bottom edge last" do
      stages["rewrite-test"] = { "rewrites" => rec(5, 2, dropped: { "s2" => 1, "s3" => 1, "s4" => 1 }) }
      svg = sankey("rewrite")
      rect_y = ->(id) { nodes(svg).find { it["data-id"] == id }["y"].to_f }
      to = layer_named(svg, "After testing on made-up edge-case data: 2")
      from = stage_nodes(svg)[stage_nodes(svg).index(to) - 1]
      sinks = ribbons(svg, "drop").select { it["data-from"] == from["data-id"] }
      expect(sinks.size).to eq(3)
      ys = sinks.to_h { |sink| [numbers(sink["d"])[0], rect_y.call(sink["data-to"])] }
      expect(ys.sort.map(&:last)).to eq(ys.values.sort.reverse)
    end

    it "keeps a count of one visible against a large one, and draws a zero count as an empty line" do
      stages["rewrite-rules"] = { "rewrites" => rec(0, 12_000, added: { "key_in_self_join" => 12_001 },
                                                               dropped: { "duplicate" => 1 }) }
      stages["llm-rewrites"] = { "rewrites" => rec(12_000, 12_000, added: { "llm" => 0 }) }
      svg = sankey("rewrite")
      one = nodes(svg, "drop").find { it["data-count"] == "1" }
      expect(one["height"].to_f).to be >= sankey_module::MIN_THICKNESS
      empty, full = ribbons(svg).partition { it["class"].split.include?("zero") }
      expect(full.map { it["data-count"].to_i }).to all(be_positive)
      expect(empty.map { [it["data-count"], it["style"]] }).to eq([["0", "fill: none; stroke: var(--sk-source)"]])
      expect(svg).not_to match(/NaN|Infinity/)
    end

    # Task 20261016-12: a source that added nothing still has its empty line into its layer.
    it "draws a diagram whose every count is zero with only empty lines, with each layer still visible" do
      stages.each_value { |by| by.each_key { |search| by[search] = rec(0, 0) } }
      %w[index rewrite].each do |id|
        svg = sankey(id)
        expect(ribbons(svg).reject { it["class"] == "ribbon source zero" && it["data-count"] == "0" }).to eq([])
        expect(stage_nodes(svg).map { it["width"].to_f }).to all(be >= sankey_module::MIN_THICKNESS)
        expect(svg).not_to match(/NaN|Infinity/)
      end
    end

    it "keeps every label clear of every other, and inside the picture, for the real stage counts" do
      stages["rewrite-test"] = { "rewrites" => rec(5, 3, dropped: (1..12).to_h { ["s#{it}", 1] }.merge("s2" => 2),
                                                         set_aside: 1) }
      stages["llm-rewrites"] = { "rewrites" => rec(2, 6, added: { "llm" => 5, "operator" => 1 },
                                                         dropped: { "inbound_check" => 1, "too_many" => 1 }) }
      stages["rewrite-rules"] = { "rewrites" => rec(0, 2, added: { "key_in_self_join" => 3, "or_to_union" => 1,
                                                                   "not_in_to_not_exists" => 2, "x" => 1 },
                                                          dropped: { "duplicate" => 2, "unparsable" => 3 }) }
      %w[index rewrite rewrite-index].each do |id|
        svg = sankey(id)
        height = svg[/viewBox="0 0 \d+ (\d+)"/, 1].to_f
        boxes = texts(svg).map do |word|
          wide = word[:text].length * 6.5
          left = word[:anchor] == "end" ? word[:x] - wide : word[:x]
          [left, word[:y] - 11, left + wide, word[:y] + 3]
        end
        expect(boxes.map(&:first).min).to be >= 0
        expect(boxes.map { it[2] }.max).to be <= 1040
        expect(boxes.map { it[1] }.min).to be >= 0
        expect(boxes.map { it[3] }.max).to be <= height
        boxes.combination(2).each do |one, other|
          apart = one[2] <= other[0] || other[2] <= one[0] || one[3] <= other[1] || other[3] <= one[1]
          expect(apart).to be(true), "labels meet in #{id}: #{one} #{other}"
        end
        bars = nodes(svg).map { [it["y"].to_f, it["y"].to_f + it["height"].to_f, it["x"].to_f] }
        drops = nodes(svg, "drop").map { [it["y"].to_f, it["y"].to_f + it["height"].to_f] }.sort
        expect(drops.each_cons(2).map { |(_, above), (below, _)| below - above }).to all(be >= 0)
        expect(bars.map(&:first)).to all(be >= 0)
      end
    end

    it "gives each ribbon and node a hover of the stage's sentence and its own numbers, and nothing else" do
      svg = sankey("rewrite")
      sentence = esc(Quaack::Driver::Report::StageSentences::TABLE.fetch("llm-rewrites"))
      node = layer_named(svg, "Combined with rewrites from the LLM: 7")
      expect(node["title"]).to eq("#{sentence} 2 came in. 5 added. 1 dropped. 6 went on.")
      source = nodes(svg, "source").find { it["data-stage"] == named("llm-rewrites") }
      expect(source["title"]).to eq("#{sentence} From the LLM: 5.")
      drop = nodes(svg, "drop").find { it["data-stage"] == named("llm-rewrites") }
      expect(drop["title"]).to eq("#{sentence} Dropped, failed the checks on what goes in: 1.")
      ribbon = ribbons(svg, "drop").find { it["data-from"] == node["data-id"] }
      expect(ribbon["title"]).to eq(drop["title"])
      carry = ribbons(svg, "carry").find { it["data-from"] == node["data-id"] }
      expect(carry["title"]).to eq("#{sentence} 6 went on.")
      expect(svg.scan(%r{<title>(.*?)</title>}m).flatten.grep(/Also counted|Held/)).to eq([])
    end

    it "says 'the rewrite' in the rewrites' index searches' hovers, and the original query's in the original's" do
      stages["index-from-query"] = { "original" => rec(0, 4, added: { "generator_one" => 4 }),
                                     "rewrite_1" => rec(0, 2, added: { "generator_one" => 2 }) }
      tip = Quaack::Driver::Report::StageSentences::TABLE.fetch("index-from-query")
      expect(sankey("index")).to include(esc(tip))
      rewrote = esc(tip.sub("the original query", "the rewrite"))
      expect(sankey("rewrite-index")).to include(rewrote)
      expect(sankey("rewrite-index")).not_to include(esc(tip))
    end

    it "draws a stage the run didn't record as a grey dashed layer that says so, never as a count" do
      stages.delete("index-test")
      svg = sankey("index")
      unknown = stage_nodes(svg).find { it["data-stage"] == named("index-test") }
      expect(unknown["class"]).to eq("node layer after unknown")
      expect(unknown["style"]).to include("var(--uncounted-fill)").and include("var(--uncounted-stroke)")
      expect(unknown).not_to have_key("data-count")
      expect(unknown["title"]).to include("not recorded").and include(esc("doesn't mean none"))
      expect(layers("index")).to include("After testing for planner utility: not recorded")
      grey = ribbons(svg).select { it["class"].split.include?("unknown") }
      expect(grey.map { it["data-from"] }).to include(unknown["data-id"])
      expect(grey.map { it["data-to"] }).to include(unknown["data-id"])
    end

    it "draws a stage that counted only what came in with its way in, and a grey way on" do
      stages["index-test"] = { "original" => rec(8, 0).except("out") }
      svg = sankey("index")
      partial = stage_nodes(svg).find { it["data-stage"] == named("index-test") }
      expect(partial["class"]).to eq("node layer after partial")
      expect(ribbons(svg).find { it["data-to"] == partial["data-id"] }["class"]).to include("unknown")
      expect(layers("index")).to include("After testing for planner utility: not recorded")
    end

    it "draws diagrams for a run that recorded no burndown, every stage not recorded and no ribbons" do
      html = render(payload)
      %w[index rewrite].each do |id|
        svg = sankey(id, html)
        expect(ribbons(svg)).to eq([])
        expect(stage_nodes(svg).map { it["class"].split.last }.uniq).to eq(["unknown"])
      end
      expect(sankey("rewrite-index", html)).to include("not recorded")
    end

    it "paints from variables the report defines in both themes, with no hex color, and names each diagram" do
      svg = sankey("rewrite")
      expect(svg).not_to match(/#\h{3,8}\b|rgb|url\(/)
      expect(svg).to start_with(%(<svg id="sankey-rewrite" class="sankey" role="img" ) +
                                %(aria-labelledby="sankey-rewrite-title"))
      expect(svg).to include(%(<title id="sankey-rewrite-title">))
      used = svg.scan(/var\((--[a-z-]+)\)/).flatten.uniq
      style = out[%r{<style>(.*?)</style>}m, 1]
      dark = style[/@media \(prefers-color-scheme: dark\) \{(.*?)\n  \}\n/m, 1]
      used.each { |name| expect(dark).to include("#{name}:"), "#{name} has no dark value" }
      expect(style).to include("svg.sankey text")
    end

    it "keeps the table with its exact numbers under the diagrams, and draws no funnel" do
      burndown = section(out, "burndown")
      expect(burndown.scan('<svg id="funnel-').size).to eq(0)
      expect(burndown.scan('<svg id="sankey-').size).to eq(3)
      expect(burndown.scan('<table id="burndown-').size).to eq(3)
      expect(burndown.rindex(%(<svg id="sankey-rewrite"))).to be < burndown.index(%(<table id="burndown-rewrite">))
    end

    it "joins stages that only add into one layer with several sources, and keeps a stage with its own sinks apart" do
      svg = sankey("index")
      layer = stage_nodes(svg).first
      expect(layer["data-stage"]).to eq("#{named("index-from-query")}; #{named("index-from-plan")}")
      bars = nodes(svg, "source").select { it["data-id"].start_with?("#{layer["data-id"]}-in") }
      expect(bars.map { it["data-count"] }).to eq(%w[7 2])
      expect(texts(svg).select { it[:kind] == "source" }.first(2).map { it[:text] })
        .to eq(["From the query&#39;s text: 7", "From the query&#39;s plan: 2"])
    end

    it "never joins a stage that sets ideas aside, even after a stage that only adds" do
      stages["index-from-plan"] = { "original" => rec(7, 8, added: { "generator_two" => 2 }, set_aside: 1) }
      expect(layers("index").first(2)).to eq(["Index ideas from the query&#39;s text: 7",
                                              "Index ideas from the query&#39;s text and plan: 9"])
    end

    it "says nothing in the picture about what came in or went on: only layers, steps, sources, and sinks" do
      %w[index rewrite rewrite-index].each do |id|
        words = texts(sankey(id)).reject { %w[step unit].include?(it[:kind]) }.map { it[:text] }
        expect(words.grep(/came in|\d+ added|\d+ went on|, went on/)).to eq([])
        expect(words).to all(satisfy { |word| word.match?(/: (\d[\d,]*|not recorded)\z/) })
      end
    end

    it "escapes its words and sets no SQL apart" do
      stages["rewrite-rules"] = { "rewrites" => rec(0, 1, added: { "<b>x" => 1 }) }
      svg = sankey("rewrite")
      expect(svg).to include("By the transform rule &lt;b&gt;x: 1")
      expect(svg).not_to include("<b>")
      expect(svg).not_to include("<code")
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
      { "node" => z, "relation" => z, "index" => z, "est_rows" => z, "actual_rows" => z, "selectivity" => nil,
        "depth" => 0 }
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
                                       "covered_by" => { "name" => z, "size_bytes" => 1 } },
                       z => { "ddl" => nil, "size" => z, "covered_by" => nil } },
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
                        "existing" => [{ "ddl" => z, "searches" => [z],
                                         "covered_by" => { "name" => z, "size_bytes" => z, "definition" => z } }] }
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

    it "prints, escaped, the round of LLM-written data that proved a rewrite wrong" do
      disproved = fated(2, "counterexamples_disproved", source: "llm", round: z)
      out = rendered(sentinels.merge("rewrites" => sentinels["rewrites"] + [disproved]))
      expect(out).to include("to break it (round #{escaped}), so it&#39;s wrong.")
      expect(out).not_to include("<zz")
    end

    it "lets no markup from a negative payload through, in text or in an attribute" do
      out = rendered(negative_sentinels)
      expect(out).not_to include("<zz")
      expect(out).not_to include('"zz')
      expect(out.scan(escaped).size).to be > 40
    end

    it "prints, escaped, every value a winning report shows" do
      expect_escaped(rendered(sentinels),
                     "<title>QUAACK report ", "<h1>QUAACK report ", "<li>", '<details class="fold query" id="',
                     %(<article class="rewrite"><details class="fold query" id="#{escaped}">\n<summary><h3>),
                     %(<span class="note">),
                     "<code>SELECT ", "transform rules ", '<li><code class="sql">',
                     '<td class="num">1</td><td>',
                     '</td><td class="num">', '<a href="#', %(<a href="##{escaped}">), '<h3>1. <a href="#', "<tr><td>",
                     "</td><td>",
                     %(<section id="explanation"><h2>Why the winner reads fewer blocks</h2>\n<p>), "<p>How it runs ",
                     "<ul><li>", '<td class="step" style="padding-left: 0.65rem">', %(<td><code class="sql">), "<td>",
                     "<td>by the transform rule ", %(<td><code class="sql">),
                     'couldn&#39;t describe (<code class="sql">')
    end

    it "prints, escaped, every value a negative report shows" do
      expect_escaped(rendered(negative_sentinels),
                     '<ul id="negative-rewrites"><li>', %(<tr><td><code class="sql">),
                     "(Postgres error code ", %(#{escaped}</td><td>), "<tbody>\n<tr><td>",
                     "</td><td>Made by transform rules ", %(<td><code class="sql">))
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
        .to include("The original query with a new index on #{sq("public.t (a) WHERE b &lt; &#39;&lt;b&gt;&#39;")}")
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

    it "names each rewrite from the same run ID everywhere, even one with a control character in it" do
      out = described_class.render(payload, run_id: "R\u0001x\u0002")
      expect(out).to eq(described_class.render(payload, run_id: "Rx"))
      name = Quaack::Driver::RewriteNames.name("Rx", 1)
      expect(section(out, "queries")).to include("Rewrite #{name}")
      expect(section(out, "ranking")).to include("Rewrite #{name}")
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
      expect(section(out, "queries")).to include("transform rule x.").and(satisfy { !it.include?('class="sql">x') })
      expect(section(out, "ranking")).to include("a new index on #{sq("public.t (a) WHERE b")}")
      expect(section(out, "explanation"))
        .to include(%(Seq Scan</td><td>#{sq("")}</td>))
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
