# frozen_string_literal: true

require "cgi"
require "quaack/driver/report"

# Task 20261011-15: a rewrite whose rewrite-test didn't finish within the
# budget isn't disproved. It goes on, and the report says, beside it and in
# the burndown, that only the LLM's test data and the real data checked it.
RSpec.describe Quaack::Driver::Report do
  def fated(number, fate, **details)
    { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => "llm", "rules" => nil,
      "fate" => fate, "scenario" => nil, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
      "untested_atoms" => [], "covered" => [], "evidence" => true }.merge(details.transform_keys(&:to_s))
  end

  def rec(inn, out, extra: {})
    { "in" => inn, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => out, "extra" => extra }
  end

  let(:rewrites) { [fated(1, "not_better", out_of_time: true), fated(2, "same_plans", out_of_time: false)] }
  let(:stages) do
    { "rewrite-test" => { "rewrite_1" => rec(1, 1, extra: { "not_tested_in_time" => 1, "untested_atoms" => 0 }) },
      "counterexamples" => { "rewrite_1" => rec(1, 1) } }
  end
  let(:payload) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => rewrites, "indexes" => {},
      "original_plan" => [], "timed_out_count" => 0, "burndown" => { "stages" => stages, "totals" => {} } }
  end
  let(:html) { CGI.unescapeHTML(described_class.render(payload, run_id: "RUN-1", llm_calls: {})) }

  let(:caution) do
    "Read it with care: its test on made-up data didn't finish within 5 minutes, so QUAACK checked it only " \
      "on test data the LLM wrote to break it and on the real data."
  end

  def summary(name) = html[%r{<h3>Rewrite #{name}</h3>.*?</summary>}m]

  it "cautions, in the summary and the open section, that only the LLM's data and the real data checked it" do
    name = html[%r{<h3>Rewrite ([^<]+)</h3>}, 1]
    expect(summary(name)).to include(caution)
    expect(html.scan(caution).size).to be >= 2
  end

  it "puts the caution on no rewrite whose test finished" do
    expect(html.scan(caution).size).to eq(2)
  end

  it "opens with the time caution when there are untested conditions too, never saying every test passed" do
    rewrites.first["untested_atoms"] = ["a < $1"]
    name = html[%r{<h3>Rewrite ([^<]+)</h3>}, 1]
    both = "#{caution} The test data also never made some conditions in a part the rewrite changed both true " \
           "and false, so the tests cannot show whether those parts behave the same in the rewrite."
    expect(summary(name)).to include(both)
    expect(html[%r{<p class="warn body-warn">(.*?)</p>}m, 1]).to eq(both)
    expect(html).not_to include("every test QUAACK ran passed")
  end

  it "keeps the usual unproven wording for a rewrite whose test finished" do
    rewrites.first.merge!("untested_atoms" => ["a < $1"], "out_of_time" => false)
    expect(html).to include("Read it with care: every test QUAACK ran passed, but the test data never made")
  end

  it "counts it in the burndown as not tested in time, gone on, not dropped" do
    burndown = html[%r{<section id="burndown">.*?</section>}m]
    table = burndown[%r{<table id="burndown-rewrite">.*?</table>}m]
    expect(table).to include("<td>not tested in time, so checked only on the LLM's test data and the real data: 1")
    sankey = burndown[%r{<svg id="sankey-rewrite-1".*?</svg>}m]
    expect(sankey).to include("1 not tested in time on made-up data went on, checked only on the LLM's test " \
                              "data and the real data.")
  end

  describe "a later fate" do
    lead = "Its test on made-up data didn't finish within 5 minutes, so QUAACK checked it only on test data " \
           "the LLM wrote to break it and on the real data"
    short = "Its test on made-up data didn't finish within 5 minutes"
    {
      ["production_mismatch", nil] =>
        ["#{lead}, and it returned different results from the original query on the real data, so it's wrong.",
         "It passed the tests on made-up data, but returned different results"],
      ["production_timed_out", nil] => ["#{lead}, and it timed out when QUAACK compared",
                                        "It passed the tests on made-up data, but timed out"],
      ["production_not_compared", nil] => ["#{lead}, but QUAACK couldn't compare its results",
                                           "It passed the tests on made-up data, but QUAACK couldn't"],
      ["below_top_three", nil] => ["#{lead}, and it beat the original query, but three others",
                                   "It passed every test and beat the original query, but three"],
      ["footprint_tie", nil] => ["#{lead}, and it beat the original query, but tied",
                                 "It passed every test and beat the original query, but tied"],
      ["measurement_timed_out", nil] => ["#{lead}, but every measurement run of it timed out.",
                                         "It passed every test, but every measurement run"],
      ["not_better", nil] => ["#{lead}, then QUAACK measured it on the real data, where it",
                              "It passed every test, then QUAACK measured it"],
      %w[unfinished rewrite-test] => ["#{short}, and the run ended before going further.",
                                      "It passed the tests on made-up data, and the run ended"],
      %w[unfinished counterexamples] => ["#{short}, it passed the LLM's test data, and the run ended before " \
                                         "measuring it.", "It passed every test, and the run ended"]
    }.each do |(fate, after), (untimed, normal)|
      it "says what happened for #{fate} #{after}, and keeps the usual words when out_of_time isn't true" do
        rewrites.replace([fated(1, fate, after:, out_of_time: true), fated(2, fate, after:, out_of_time: "true")])
        sentences = html.scan(%r{<span class="fate">What became of it: (.*?)</span>}m).flatten
        expect(sentences.first).to include(untimed)
        expect(sentences.first).not_to match(/passed (the tests on made-up data|every test)/)
        expect(sentences.last).to include(normal)
      end
    end
  end
end
