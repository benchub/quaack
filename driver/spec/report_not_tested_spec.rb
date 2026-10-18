# frozen_string_literal: true

require "cgi"
require "quaack/driver/report"

# Task 20261012-4: a rewrite the search couldn't test isn't disproved. It
# goes on, as one out of time does (20261011-15), and the report says why
# beside it, by a fixed reason word (Protocol::FuzzResult::NOT_TESTED), and
# that only the LLM's test data and the real data checked it.
RSpec.describe Quaack::Driver::Report do
  def fated(number, fate, **details)
    { "rewrite" => "rewrite_#{number}", "sql" => "SELECT #{number}", "source" => "llm", "rules" => nil,
      "fate" => fate, "rule" => nil, "round" => nil, "after" => nil, "plan" => nil,
      "untested_atoms" => [], "covered" => [], "evidence" => true }.merge(details.transform_keys(&:to_s))
  end

  let(:rewrites) { [fated(1, "not_better", not_tested: "no_world"), fated(2, "same_plans", not_tested: nil)] }
  let(:payload) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "rewrites" => rewrites, "indexes" => {},
      "original_plan" => [], "timed_out_count" => 0, "burndown" => { "stages" => {}, "totals" => {} } }
  end
  let(:html) { CGI.unescapeHTML(described_class.render(payload, run_id: "RUN-1", llm_calls: {})) }

  def summary(name) = html[%r{<h3>Rewrite #{name}</h3>.*?</summary>}m]

  def caution(why)
    "Read it with care: QUAACK didn't test it on made-up data, since #{why}, so it checked it only on test data " \
      "the LLM wrote to break it and on the real data."
  end

  {
    "no_tables" => "its queries read no table",
    "not_comparable" => "QUAACK can't compare the results of FETCH FIRST ... WITH TIES row for row",
    "setup_failed" => "QUAACK couldn't build small databases for its tables",
    "no_world" => "no small database QUAACK built let both queries run",
    "unconfirmed" => "time ran out while QUAACK was confirming a difference it may have found",
    "search_failed" => "the test stopped on an error",
    "fuzz_off" => "a test setting turned the test off"
  }.each do |reason, why|
    it "cautions, in the summary and the open section, why a rewrite went on untested: #{reason}" do
      rewrites.first["not_tested"] = reason
      name = html[%r{<h3>Rewrite ([^<]+)</h3>}, 1]
      expect(summary(name)).to include(caution(why))
      expect(html.scan(caution(why)).size).to eq(2)
    end
  end

  it "has words for every reason the protocol allows, and only those" do
    expect(Quaack::Driver::Report::Words::NOT_TESTED.keys).to eq(Quaack::Protocol::FuzzResult::NOT_TESTED)
  end

  it "puts no such caution on a rewrite the search tested" do
    rewrites.first["not_tested"] = nil
    expect(html).not_to include("didn't test it on made-up data")
  end

  it "says only why it went untested when there are untested conditions too" do
    rewrites.first["untested_atoms"] = ["a < $1"]
    expect(html[%r{<p class="warn body-warn">(.*?)</p>}m, 1])
      .to eq(caution("no small database QUAACK built let both queries run"))
    expect(summary(html[%r{<h3>Rewrite ([^<]+)</h3>}, 1])).not_to include("both true and false")
  end

  it "counts it in the burndown as not tested by the random search, gone on, not dropped" do
    record = { "in" => 1, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 1,
               "extra" => { "trials" => 0, "untested" => 1 } }
    payload["burndown"]["stages"].merge!("fuzz" => { "rewrite_1" => record },
                                         "counterexamples" => { "rewrite_1" => record.merge("extra" => {}) })
    burndown = html[%r{<section id="burndown">.*?</section>}m]
    table = burndown[%r{<table id="burndown-rewrite">.*?</table>}m]
    expect(table).to include("not tested by the random search, so checked only on the LLM's test data and the " \
                             "real data: 1")
    sankey = burndown[%r{<svg id="sankey-rewrite-1".*?</svg>}m]
    expect(sankey).to include("1 not tested on made-up data went on, checked only on the LLM's test data and the " \
                              "real data.")
  end

  describe "a later fate" do
    short = "QUAACK didn't test it on made-up data, since no small database QUAACK built let both queries run"
    lead = "#{short}, so QUAACK checked it only on test data the LLM wrote to break it and on the real data"
    {
      ["production_mismatch", nil] =>
        ["#{lead}, and it returned different results from the original query on the real data, so it's wrong.",
         "It passed the tests on made-up data, but returned different results"],
      ["below_top_three", nil] => ["#{lead}, and it beat the original query, but three others",
                                   "It passed every correctness test and beat the original query, but three"],
      ["not_better", nil] => ["#{lead}, but when measured it performed too poorly to be ranked.",
                              "It passed every correctness test, but when measured against real data"],
      %w[unfinished rewrite-test] => ["#{short}, and the run ended before going further.",
                                      "It passed the tests on made-up data, and the run ended"],
      %w[unfinished counterexamples] => ["#{short}, it passed the LLM's test data, and the run ended before " \
                                         "measuring it.", "It passed every correctness test, and the run ended"]
    }.each do |(fate, after), (untested, normal)|
      it "says what happened for #{fate} #{after}, and keeps the usual words without a reason" do
        rewrites.replace([fated(1, fate, after:, not_tested: "no_world"), fated(2, fate, after:, not_tested: nil)])
        sentences = html.scan(%r{<span class="fate">What became of it: (.*?)</span>}m).flatten
        expect(sentences.first).to include(untested)
        expect(sentences.first).not_to match(/passed (the tests on made-up data|every (correctness )?test)/)
        expect(sentences.last).to include(normal)
      end
    end
  end
end
