# frozen_string_literal: true

require "quaack/driver/report"

# DESIGN.md's report, for several LLM providers: what the driver's own
# provenance record and call counts say about which provider did what.
# Anything the record lacks is "not recorded", never a guess.
RSpec.describe Quaack::Driver::Report do
  def fated(number, fate, **details)
    { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => nil, "rules" => nil,
      "fate" => fate, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
      "untested_atoms" => nil, "covered" => nil, "evidence" => nil }.merge(details.transform_keys(&:to_s))
  end

  def rec(added: {}, dropped: {})
    { "in" => 0, "added" => added, "dropped" => dropped, "set_aside" => 0, "out" => 0, "extra" => {} }
  end

  def provider(name, type, model, down = nil)
    { "name" => name, "provider" => type, "model" => model,
      "down" => down }.compact
  end

  def counts(written, rules = {}) = { "written" => written, "outcomes" => {}, "rules" => rules }

  let(:rewrites) do
    [fated(1, "not_better", source: "llm", covered: []), fated(2, "same_plans", source: "llm"),
     fated(3, "ranked", source: "llm"), fated(4, "same_plans", source: "rule", rules: ["key_in_self_join"],
                                                               covered: [])]
  end
  let(:stages) do
    { "llm-rewrites" => { "rewrites" => rec(added: { "llm" => 5 }) },
      "llm-index-ideas" => { "original" => rec(added: { "llm" => 4 }, dropped: { "covered_by_existing" => 1 }),
                             "rewrite_1" => rec(added: { "llm" => 2 }) },
      "llm-index-refine" => { "original" => rec(added: { "llm" => 1 }) } }
  end
  let(:payload) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => rewrites, "indexes" => {},
      "original_plan" => [], "timed_out_count" => 0, "burndown" => { "stages" => stages, "totals" => {} } }
  end
  let(:record) do
    { "providers" => [provider("groq", "openai_compatible", "llama-<b>4</b>", "llm_rate_limited"),
                      provider("opus", "anthropic", "claude-opus-5-5"),
                      provider("gpt", "copilot_cli", "gpt-5.5", "llm_auth")],
      "rewrites" => { "rewrite_1" => "groq", "rewrite_3" => "opus" },
      "rewrites_proposed" => { "groq" => 3, "opus" => 2 },
      "counterexamples" => { "rewrite_1" => [{ "entry" => "groq", "rounds" => 1 },
                                             { "entry" => "opus", "rounds" => 2, "after" => "llm_rate_limited" }] },
      "index_ideas" => { "original" => { "first" => { "groq" => counts(4, "covered_by_existing" => 1) },
                                         "refinement" => { "opus" => counts(1) } },
                         "rewrite_1" => { "first" => { "opus" => counts(2) } } } }
  end
  let(:calls) do
    { "groq" => { "llm-rewrites" => 1, "llm-counterexamples" => 2 },
      "opus" => { "llm-index-ideas" => 1, "llm-counterexamples" => 2 }, "gpt" => {} }
  end
  let(:llm_calls) { { "llm-index-ideas" => 1, "llm-rewrites" => 1, "llm-counterexamples" => 4 } }
  let(:html) do
    described_class.render(payload, run_id: "RUN-1", llm_calls:, llm: { "record" => record, "calls" => calls })
  end

  def summary(number) = html[%r{<details class="query" id="rewrite-#{number}">.*?</summary>}m]
  def details(number) = html[%r{<details class="query" id="rewrite-#{number}">.*?</details></article>}m]

  def rows(id)
    table = html[%r{<table id="#{id}">.*?</table>}m]
    table.scan(%r{<tr><th scope="row">(.*?)</th>(.*?)</tr>})
         .to_h { |name, cells| [name, cells.scan(%r{<td[^>]*>(.*?)</td>}).flatten] }
  end

  def header(id) = html[%r{<table id="#{id}">.*?</thead>}m].scan(%r{<th scope="col"[^>]*>(.*?)</th>}).flatten

  describe "where each rewrite came from" do
    it "names the provider entry and model that wrote an LLM rewrite, its model set apart and escaped" do
      expect(summary(1)).to include("Where it came from: suggested by the LLM (groq, " \
                                    "<code>llama-&lt;b&gt;4&lt;/b&gt;</code>).")
      expect(summary(3)).to include("suggested by the LLM (opus, <code>claude-opus-5-5</code>).")
    end

    it "says the model wasn't recorded when the record lacks the rewrite's author" do
      expect(summary(2)).to include("Where it came from: suggested by the LLM (its model wasn&#39;t recorded).")
    end

    it "says which providers ran each rewrite's counterexample rounds, and why a fresh start began" do
      expect(details(1)).to include(
        "<p class=\"counterexamples\">groq wrote the test data meant to break it in round 1, then opus in rounds " \
        "2 and 3, starting fresh after groq was rate limited.</p>"
      )
    end

    it "says who wrote a rewrite's test data wasn't recorded when rounds ran and the record lacks them" do
      expect(details(4)).to include("<p class=\"counterexamples\">Who wrote the test data meant to break it: " \
                                    "not recorded.</p>")
      expect(details(2)).not_to include("counterexamples")
    end
  end

  # DESIGN.md, "Several LLM providers" (Adversarial pairing) and report:
  # each rewrite's pairing outcome, from the record, and a warning in its
  # summary when the pairing wasn't met or couldn't be checked.
  describe "the counterexample pairing" do
    let(:rewrites) do
      [fated(1, "not_better", source: "llm", covered: []), fated(2, "not_better", source: "llm", covered: []),
       fated(3, "not_better", source: "llm", covered: []), fated(4, "not_better", source: "rule", covered: []),
       fated(5, "not_better", source: "operator", covered: []), fated(6, "not_better", source: "llm", covered: []),
       fated(7, "not_better", source: "llm", covered: []),
       fated(8, "not_better", source: "llm", untested_atoms: ["a < $1"], covered: [])]
    end
    let(:record) do
      unit = ->(entry, pairing, **more) { { "entry" => entry, "rounds" => 1, "pairing" => pairing, **more } }
      { "providers" => [provider("groq", "openai_compatible", "llama"), provider("opus", "anthropic", "opus-m")],
        "rewrites" => { "rewrite_1" => "groq", "rewrite_2" => "groq", "rewrite_6" => "groq" },
        "counterexamples" => {
          "rewrite_1" => [unit.call("opus", "met")],
          "rewrite_2" => [unit.call("opus", "met"), unit.call("groq", "not_met", "after" => "llm_rate_limited")],
          "rewrite_3" => [unit.call("groq", "unchecked")], "rewrite_4" => [unit.call("groq", "unchecked")],
          "rewrite_5" => [unit.call("groq", "unchecked")], "rewrite_6" => [unit.call("groq", "not_applicable")],
          "rewrite_7" => [{ "entry" => "groq", "rounds" => 1 }], "rewrite_8" => [unit.call("groq", "not_met")]
        } }
    end

    def line(number) = details(number)[%r{<p class="counterexamples">(.*?)</p>}, 1]
    def warn(number) = summary(number)[%r{<span class="warn">(.*?)</span>}, 1]

    it "says the pairing was met, with no warning" do
      expect(line(1)).to eq("opus wrote #{Quaack::Driver::Report::Providers::TEST_DATA} in round 1. " \
                            "The pairing was met: a different model from the one that wrote the rewrite wrote all " \
                            "its test data.")
      expect(warn(1)).to be_nil
    end

    it "says the pairing wasn't met when any unit ran on the author, with a warning in the summary" do
      expect(line(2)).to end_with("starting fresh after opus was rate limited. The pairing wasn&#39;t met: no other " \
                                  "provider was left, so the model that wrote the rewrite also wrote test data " \
                                  "meant to break it.")
      expect(warn(2)).to eq("Read it with care: a model checked its own work, since the one that wrote it also " \
                            "wrote test data meant to break it.")
    end

    it "capitalizes the pairing's warning when it follows another warning in the summary" do
      expect(warn(8)).to eq("Read it with care: the test data left some of its conditions untested. A model " \
                            "checked its own work, since the one that wrote it also wrote test data meant to " \
                            "break it.")
    end

    it "says the pairing couldn't be checked for an LLM rewrite whose author wasn't recorded, with a warning" do
      expect(line(3)).to end_with(" The pairing couldn&#39;t be checked, since the record doesn&#39;t say which " \
                                  "model wrote the rewrite.")
      expect(warn(3)).to eq("Read it with care: nothing could check that a different model wrote its test data.")
    end

    it "says nothing of pairing for a rule-made or operator rewrite, or when the pairing is any or unrecorded" do
      [4, 5, 6, 7].each do |number|
        expect(line(number)).to eq("groq wrote #{Quaack::Driver::Report::Providers::TEST_DATA} in round 1.")
        expect(warn(number)).to be_nil
      end
    end
  end

  describe "who proposed what" do
    it "splits the LLM's rewrites row into a row per provider, under the LLM total" do
      counted = rows("accountability-rewrites")
      expect(counted.keys).to eq([esc("QUAACK's own rules"), "The LLM", "The LLM: groq", "The LLM: opus",
                                  "The LLM: not recorded", "You"])
      expect(counted["The LLM"]).to eq(%w[5 2 1 0 1 1 0])
      expect(counted["The LLM: groq"]).to eq(%w[3 2 0 0 1 0 0])
      expect(counted["The LLM: opus"]).to eq(%w[2 1 0 0 0 1 0])
      expect(counted["The LLM: not recorded"]).to eq(["not recorded", "not recorded", "1", "0", "0", "0", "0"])
    end

    it "splits the LLM's indexes row by provider for what the record counts, and says not recorded for the rest" do
      counted = rows("accountability-indexes")
      expect(counted.keys.take(5)).to eq([esc("Generator one, from the query's text"),
                                          esc("Generator two, from the query's plan"), "The LLM", "The LLM: groq",
                                          "The LLM: opus"])
      missing = ["not recorded"] * 4
      expect(counted["The LLM: groq"]).to eq(%w[4 1] + missing)
      expect(counted["The LLM: opus"]).to eq(%w[3 0] + missing)
      expect(html).to include("For each provider, only what it proposed and what already existed are recorded.")
    end

    it "says not recorded for every provider when the record's counts don't add up to the LLM's" do
      record["rewrites_proposed"] = { "groq" => 3 }
      record["index_ideas"].delete("rewrite_1")
      rewrites = rows("accountability-rewrites")
      expect(rewrites.keys).to include("The LLM: groq", "The LLM: opus", "The LLM: not recorded")
      expect(rewrites.select { |name, _| name.start_with?("The LLM: ") }.values).to all(eq(["not recorded"] * 7))
      expect(rewrites["The LLM"]).to eq(%w[5 2 1 0 1 1 0])
      expect(rows("accountability-indexes")["The LLM: groq"]).to eq(["not recorded"] * 6)
    end

    it "has no note on the rows by provider when the tables don't split" do
      record["providers"] = record["providers"].take(1)
      expect(rows("accountability-indexes").keys).not_to include("The LLM: groq")
      expect(html).not_to include(Quaack::Driver::Report::Providers::PER_PROVIDER)
    end
  end

  describe "the LLM providers table" do
    it "has a row per entry: its provider type, model, calls, and whether the run marked it down or dropped it" do
      expect(header("llm-providers")).to eq(["Name", "Provider", "Model", "Calls", "Marked down or dropped"])
      expect(rows("llm-providers")).to eq(
        "groq" => ["openai_compatible", "<code>llama-&lt;b&gt;4&lt;/b&gt;</code>", "3",
                   "marked down, since it was rate limited"],
        "opus" => ["anthropic", "<code>claude-opus-5-5</code>", "3", "no"],
        "gpt" => ["copilot_cli", "<code>gpt-5.5</code>", "0", "dropped, since its credentials were refused"]
      )
    end

    it "says not recorded for the calls of an entry this run of quaack didn't have" do
      calls.delete("gpt")
      expect(rows("llm-providers")["gpt"][2]).to eq("not recorded")
    end
  end

  describe "LLM calls" do
    it "is a table with a row per step and a column per provider, then all of them together" do
      expect(header("llm-calls")).to eq(["What it was for", "groq", "opus", "gpt", "All providers"])
      expect(rows("llm-calls")).to eq(
        "Index suggestions for the original query" => %w[0 1 0 1],
        "Rewrite suggestions" => %w[1 0 0 1],
        "Test data written to break the rewrites" => %w[2 2 0 4]
      )
    end
  end

  context "with one provider, from an llm block" do
    let(:record) do
      { "providers" => [provider("anthropic", "anthropic", "claude-opus-5-5")],
        "rewrites" => { "rewrite_1" => "anthropic", "rewrite_2" => "anthropic", "rewrite_3" => "anthropic" },
        "rewrites_proposed" => { "anthropic" => 5 } }
    end
    let(:calls) { { "anthropic" => llm_calls } }

    it "names it, and splits no table by provider" do
      expect(summary(1)).to include("suggested by the LLM (anthropic, <code>claude-opus-5-5</code>).")
      expect(rows("accountability-rewrites").keys).to eq([esc("QUAACK's own rules"), "The LLM", "You"])
      expect(rows("accountability-indexes").keys).not_to include(a_string_starting_with("The LLM:"))
      expect(header("llm-calls")).to eq(["What it was for", "anthropic"])
      expect(rows("llm-providers").keys).to eq(["anthropic"])
    end
  end

  it "says not recorded, and names no provider, when there's no record" do
    out = described_class.render(payload, run_id: "RUN-1", llm_calls:)
    expect(out).to include("suggested by the LLM (its model wasn&#39;t recorded).")
    expect(out).to include(%(<p class="counterexamples">Who wrote the test data meant to break it: not recorded.</p>))
    expect(out).not_to include(%(<table id="llm-providers">))
    expect(out).to include("No LLM provider was recorded for this run.")
  end

  def esc(text) = text.gsub("'", "&#39;")
end
