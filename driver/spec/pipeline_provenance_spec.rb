# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/pipeline"
require "quaack/driver/provenance"
require "quaack/driver/transport/base"
require_relative "support/fake_llm"

# DESIGN.md's "Several LLM providers" (Provenance): the steps write the
# record as they go, and nothing in it, or in what goes to the enclave,
# is new. Each provider's name and model are sentinels, and so are the
# payloads and the LLM's replies.
RSpec.describe "The pipeline's provenance record" do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      example.run
    end
  end

  let(:run_id) { "20261008T120000Z-0123abcd" }
  let(:names) { %w[sentinel-name-a sentinel-name-b] }
  let(:models) { %w[SENTINEL_MODEL_A SENTINEL_MODEL_B] }
  let(:fakes) { names.to_h { [it, FakeLLM.new] } }
  let(:fa) { fakes[names[0]] }
  let(:fb) { fakes[names[1]] }
  # The entry llm-rewrites is pinned to, its routing, and llm_routing's
  # counterexample_pairing, if any.
  let(:rewriter) { names[1] }
  let(:rewrites_routing) { { "providers" => [rewriter] } }
  let(:pairing) { nil }
  let(:router) do
    config = { "llms" => names.zip(models).map do |name, model|
      { "name" => name, "provider" => "anthropic", "model" => model }
    end,
               "llm_routing" => { "mode" => "failover", "counterexample_pairing" => pairing,
                                  "steps" => { "llm-rewrites" => rewrites_routing } }.compact }
    clients = names.zip(models).map do |name, model|
      fakes[name].client(burndown: Quaack::Driver::Burndown.new, model:, max_retries: 0)
    end
    Quaack::Driver::LLM::Router.for(Quaack::Driver::LLM.providers(config, env: {}), clients)
  end

  # The sentinels that must never reach the record: what the enclave sent
  # for the LLM, and what the LLM wrote.
  let(:secret) { %w[SENTINEL_PAYLOAD SENTINEL_DDL SENTINEL_REWRITE_SQL SENTINEL_INSERT SENTINEL_REASON] }

  let(:initial) do
    { "index_search_original" => false, "index_generated_original" => false, "index_ranking_original" => false,
      "rewrite_rules_applied" => true, "rewrites_generated" => false,
      **%w[arena_setup index_build baseline index_baseline candidate_runs minimax result_comparison
           selection].to_h { [it, true] } }
  end
  let(:later) do
    initial.merge("index_search_original" => true, "index_generated_original" => true, "index_ranking_original" => true,
                  "rewrites_generated" => true, "rewrite_1" => true, "index_search_rewrite_1" => true,
                  "index_ranking_rewrite_1" => true, "rewrite_pruned_1" => true)
  end

  let(:feedback) { { "type" => "index_feedback", "revise" => false, "refined" => false } }

  def outcome(index, outcome, rule = nil)
    { "type" => "index_outcome", "index" => index, "outcome" => outcome, "rule" => rule, "covered_by" => nil,
      "partial_constant_only" => false }
  end

  let(:transport) do
    first = initial
    rest = later
    replies = {
      "index-payload" => [{ "type" => "index_payload", "query" => "SELECT SENTINEL_PAYLOAD" }],
      "index-test" => [outcome(1, "accepted"), outcome(2, "dropped", "duplicate")],
      "index-feedback" => [feedback],
      "rewrite-payload" => [{ "type" => "rewrite_payload", "query" => "SELECT SENTINEL_PAYLOAD" }],
      "rewrite-check" => [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rule" => nil,
                            "rewrite" => "rewrite_1", "warnings" => [] },
                          { "type" => "rewrite_outcome", "index" => 2, "outcome" => "rejected", "rule" => "too_many",
                            "rewrite" => nil, "warnings" => [] }],
      "rewrite-test" => [{ "type" => "rewrite_test", "passed" => true }],
      "counterexample-payload" => [{ "type" => "counterexample_payload", "original" => "SELECT SENTINEL_PAYLOAD" }],
      "counterexample-round" => [{ "type" => "counterexample_round", "match" => true, "rule" => nil,
                                   "covered" => [], "refused" => [{ "index" => 0, "rule" => "SENTINEL_REASON" }] }],
      "report-payload" => [report]
    }
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |subcommand, **options|
        Quaack::Driver::Transport::Base.new.send(:argv, subcommand, options.fetch(:args, {}))
        entries = @calls.none? { it.first == "status" } ? first : rest
        @calls << [subcommand, options]
        status = [{ "type" => "status", "entries" => entries }]
        Data.define(:messages).new(messages: subcommand == "status" ? status : replies.fetch(subcommand, []))
      end
    end.new
  end

  let(:path) { File.join(@home, ".quaack", "runs", "#{run_id}.llm.json") }

  let(:report) do
    { "type" => "report", "top" => [], "excluded" => {}, "infinite_sets" => [], "original_sql" => "SELECT 1",
      "original_measurements" => {}, "labels" => [], "indexes" => {}, "original_plan" => [], "timed_out_count" => 0,
      "rewrites" => [{ "rewrite" => "rewrite_1", "sql" => "SELECT 2", "source" => "llm", "fate" => "same_plans",
                       "covered" => [] }] }
  end

  def run(out: nil)
    Quaack::Driver::Pipeline.new(transport:, client: router, run_id:, home: @home, out:).run
  end

  def script
    fa.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX SENTINEL_DDL ON public.t (a)",
                                                "CREATE INDEX ON public.t (b)"] })
    fa.cut_short("llm-index-ideas", "par")
    fb.reply("llm-rewrites", { "rewrites" => [{ "sql" => "SELECT SENTINEL_REWRITE_SQL", "transformation" => "t",
                                                "assumptions" => [] },
                                              { "sql" => "SELECT 2", "transformation" => "t", "assumptions" => [] }] })
    fa.reply("llm-counterexamples", { "inserts" => ["INSERT INTO public.t (a) VALUES ('SENTINEL_INSERT')"] })
    fa.error("llm-counterexamples", status: 429)
    2.times { fb.reply("llm-counterexamples", { "inserts" => ["INSERT INTO public.t (a) VALUES (1)"] }) }
  end

  # The sentinels in text: each of words that it holds.
  def found(text, words) = words.select { text.include?(it) }

  # Everything sent to the enclave, as text.
  def to_enclave = JSON.generate(transport.calls)

  # Every prompt sent to an LLM, as text: the system prompts and messages.
  def prompts = JSON.generate(fakes.values.flat_map(&:asks).map { [it.body[:system], it.body[:messages]] })

  it "records, as it goes, which provider and model produced each idea, rewrite, and counterexample round" do
    script
    run
    record = JSON.parse(File.read(path))
    usage = record.delete("llm_usage")

    # The first entry's cut-short reply spent tokens but wasn't used.
    expect(usage.transform_values { it.except("seconds") })
      .to eq(names[0] => { "used" => 2, "reported" => 3, "input" => 3, "output" => 3 },
             names[1] => { "used" => 3, "reported" => 3, "input" => 3, "output" => 3 })
    expect(usage.values.map { it["seconds"] }).to all(be_positive)
    expect(record).to eq(
      "providers" => [{ "name" => names[0], "provider" => "anthropic", "model" => models[0],
                        "down" => "llm_rate_limited" },
                      { "name" => names[1], "provider" => "anthropic", "model" => models[1] }],
      "index_ideas" => { "original" => {
        "first" => { names[0] => { "written" => 2, "outcomes" => { "accepted" => 1, "dropped" => 1 },
                                   "rules" => { "duplicate" => 1 } } },
        "skipped" => [{ "entry" => names[0], "rule" => "llm_bad_response" }]
      } },
      "rewrites" => { "rewrite_1" => names[1] },
      "rewrites_proposed" => { names[1] => 2 },
      "llm_calls" => { "steps" => { "llm-counterexamples" => 4, "llm-index-ideas" => 2, "llm-rewrites" => 1 },
                       "providers" => { names[0] => { "llm-counterexamples" => 2, "llm-index-ideas" => 2 },
                                        names[1] => { "llm-counterexamples" => 2, "llm-rewrites" => 1 } } },
      "counterexamples" => { "rewrite_1" => [{ "entry" => names[0], "rounds" => 1, "pairing" => "not_applicable" },
                                             { "entry" => names[1], "rounds" => 2, "after" => "llm_rate_limited",
                                               "pairing" => "not_applicable" }] }
    )
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  # DESIGN.md, "Several LLM providers" (Adversarial pairing): the
  # rewrite's author comes from the record, so its rounds go elsewhere.
  context "with counterexample_pairing prefer_different, and the first entry writing the rewrite" do
    let(:rewriter) { names[0] }
    let(:pairing) { "prefer_different" }

    def script
      fa.reply("llm-index-ideas", { "indexes" => ["CREATE INDEX ON public.t (a)", "CREATE INDEX ON public.t (b)"] })
      fa.cut_short("llm-index-ideas", "par")
      rewrite = { "sql" => "SELECT 2", "transformation" => "t", "assumptions" => [] }
      fa.reply("llm-rewrites", { "rewrites" => [rewrite] })
      3.times { fb.reply("llm-counterexamples", { "inserts" => ["INSERT INTO public.t (a) VALUES (1)"] }) }
    end

    it "runs the rewrite's counterexample rounds off its author, and records that the pairing was met" do
      script
      run

      expect(JSON.parse(File.read(path))["counterexamples"])
        .to eq("rewrite_1" => [{ "entry" => names[1], "rounds" => 3, "pairing" => "met" }])
      expect(fa.asks.map(&:step)).not_to include("llm-counterexamples")
    end

    it "puts no provider's name or model, the author's included, in a prompt or anything sent to the enclave" do
      script
      run

      expect(found(to_enclave + prompts, names + models)).to eq([])
      expect(fb.asks.map(&:step)).to include("llm-counterexamples")
    end

    it "says in the report that the pairing was met" do
      script
      out = File.join(@home, "report.html")
      run(out:)

      expect(File.read(out)).to include("#{names[1]} wrote the test data meant to break it in rounds 1, 2, and 3. " \
                                        "The pairing was met: ")
    end
  end

  it "keeps SQL, DDL, payloads, replies, and the enclave's words out of the record" do
    script
    run

    expect(found(File.read(path), secret)).to eq([])
    expect(found(prompts, secret)).not_to be_empty
  end

  it "sends nothing new to the enclave or into a prompt: no provider's name or model" do
    script
    run

    expect(found(to_enclave + prompts, names + models)).to eq([])
    expect(found(File.read(path), names + models)).to eq(names + models)
  end

  it "would catch a sentinel planted where it mustn't be" do
    expect(found("x SENTINEL_DDL y", secret)).to eq(["SENTINEL_DDL"])
    expect(found(JSON.generate([["opus", names[1]]]), names + models)).to eq([names[1]])
  end

  it "builds the report from the record and this run's calls by provider" do
    script
    out = File.join(@home, "report.html")
    run(out:)
    html = File.read(out)

    expect(html).to include("suggested by the LLM (#{names[1]}, <code>#{models[1]}</code>).")
    expect(html).to include("#{names[0]} wrote the test data meant to break it in round 1, then #{names[1]} in " \
                            "rounds 2 and 3, starting fresh after #{names[0]} was rate limited.")
    expect(html[%r{<table id="llm-providers">.*?</table>}m])
      .to include("<tr><th scope=\"row\">#{names[0]}</th><td>anthropic</td><td><code>#{models[0]}</code></td>" \
                  "<td class=\"num\">4</td><td>marked down, since it was rate limited</td></tr>")
    expect(html[%r{<table id="llm-calls">.*?</table>}m])
      .to include("<tr><th scope=\"row\">Rewrite suggestions</th><td class=\"num\">0</td><td class=\"num\">1</td>" \
                  "<td class=\"num\">1</td></tr>")
  end

  # DESIGN.md, "Several LLM providers" (Routing, Provenance, Limits).
  context "when llm-rewrites fans out" do
    let(:rewrites_routing) { { "fan_out" => true } }

    before do
      script
      fa.reply("llm-rewrites", { "rewrites" => [{ "sql" => "SELECT 3", "transformation" => "t", "assumptions" => [] },
                                                { "sql" => "SELECT 4", "transformation" => "t",
                                                  "assumptions" => [] }] })
    end

    it "checks the union in one interleaved call and credits each stored rewrite to its branch, by position" do
      out = File.join(@home, "report.html")
      run(out:)
      checks = transport.calls.select { it.first == "rewrite-check" }

      expect(checks.map { |_, options| options.dig(:input, "rewrites").map { it["sql"] } })
        .to eq([["SELECT 3", "SELECT SENTINEL_REWRITE_SQL", "SELECT 4", "SELECT 2"]])
      record = JSON.parse(File.read(path))
      expect([record["rewrites"], record["rewrites_proposed"]])
        .to eq([{ "rewrite_1" => names[0] }, { names[0] => 2, names[1] => 2 }])
      expect(File.read(out)).to include("suggested by the LLM (#{names[0]}, <code>#{models[0]}</code>).")
    end

    it "sends no provider's name or model to the enclave or into a prompt, and keeps SQL out of the record" do
      run

      expect(found(to_enclave + prompts, names + models)).to eq([])
      expect(found(File.read(path), secret + ["SELECT 3"])).to eq([])
    end
  end

  # DESIGN.md, "Several LLM providers" (Routing, Provenance): a dropped
  # branch is in the record by step, entry, and rule, and in the report.
  context "when a branch of llm-rewrites fails" do
    let(:rewrites_routing) { { "fan_out" => true } }

    before do
      script
      fa.cut_short("llm-rewrites", "SENTINEL_REASON")
    end

    it "records the branch's step, entry, and rule only, and the report says so" do
      out = File.join(@home, "report.html")
      run(out:)

      expect(JSON.parse(File.read(path))["failed_branches"])
        .to eq([{ "step" => "llm-rewrites", "entry" => names[0], "rule" => "llm_bad_response" }])
      expect(found(File.read(path), secret + ["max_tokens"])).to eq([])
      expect(File.read(out)).to include("<li>Rewrite suggestions: #{names[0]} gave a reply QUAACK couldn&#39;t use, " \
                                        "so the step went on without it.</li>")
    end
  end

  # DESIGN.md, "Several LLM providers" (Provenance): the refinement rounds
  # and a rewrite's own index search are recorded too.
  context "with a refinement round, and a rewrite's index search" do
    let(:feedback) do
      { "type" => "index_feedback", "revise" => true, "refined" => false, "baseline" => [1.0],
        "candidates" => [{ "shortfall" => "unused" }] }
    end
    let(:later) { super().merge("rewrite_index_ideas_1" => true) }

    def script
      super
      fa.reply("llm-index-refine", { "indexes" => ["CREATE INDEX ON public.t (c)", "CREATE INDEX ON public.t (f)"] })
      fb.reply("rewrite-llm-index-ideas",
               { "indexes" => ["CREATE INDEX ON public.t (d)", "CREATE INDEX ON public.t (g)"] })
      fb.cut_short("rewrite-llm-index-ideas", "par")
      fb.reply("rewrite-llm-index-refine",
               { "indexes" => ["CREATE INDEX ON public.t (e)", "CREATE INDEX ON public.t (h)"] })
    end

    # The first entry is marked down by the rewrite's index search, so the
    # second writes its rounds.
    it "records each refinement round and the rewrite's rounds under the entry that wrote them" do
      script
      run

      tally = { "written" => 2, "outcomes" => { "accepted" => 1, "dropped" => 1 }, "rules" => { "duplicate" => 1 } }
      ideas = JSON.parse(File.read(path))["index_ideas"]
      expect(ideas["original"]["refinement"]).to eq(names[0] => tally)
      expect(ideas["rewrite_1"]).to eq("first" => { names[1] => tally }, "refinement" => { names[1] => tally },
                                       "skipped" => [{ "entry" => names[1], "rule" => "llm_bad_response" }])
    end
  end

  # DESIGN.md, "Several LLM providers" (Provenance).
  it "clears an earlier run's down for a provider this run asked without marking it down" do
    Quaack::Driver::Provenance.open(@home, run_id)
                              .providers!([{ "name" => "old", "provider" => "anthropic", "model" => "m" },
                                           { "name" => names[1], "provider" => "anthropic", "model" => models[1] }])
                              .down!("old" => "llm_unavailable", names[1] => "llm_auth")
                              .save
    script
    run

    expect(JSON.parse(File.read(path))["providers"].to_h { [it["name"], it["down"]] })
      .to eq("old" => "llm_unavailable", names[1] => nil, names[0] => "llm_rate_limited")
  end

  # DESIGN.md, "Several LLM providers" (Provenance): only a provider this
  # run asked loses an earlier run's down.
  context "with a third entry this run never asks" do
    let(:names) { %w[sentinel-name-a sentinel-name-b sentinel-name-c] }
    let(:models) { %w[SENTINEL_MODEL_A SENTINEL_MODEL_B SENTINEL_MODEL_C] }

    it "keeps that entry's earlier down" do
      Quaack::Driver::Provenance.open(@home, run_id)
                                .providers!([{ "name" => names[2], "provider" => "anthropic", "model" => models[2] }])
                                .down!(names[2] => "llm_unavailable")
                                .save
      script
      run

      expect(fakes[names[2]].asks).to eq([])
      expect(JSON.parse(File.read(path))["providers"].to_h { [it["name"], it["down"]] })
        .to eq(names[2] => "llm_unavailable", names[0] => "llm_rate_limited", names[1] => nil)
    end
  end

  it "keeps the record from before a resume, and adds to it" do
    File.write(File.join(@home, "x"), "")
    Quaack::Driver::Provenance.open(@home, run_id)
                              .providers!([{ "name" => "old", "provider" => "anthropic", "model" => "m" }])
                              .rewrites!([{ "index" => 1, "outcome" => "accepted", "rewrite" => "rewrite_9" }],
                                         entries: %w[old])
                              .save
    script
    run

    record = JSON.parse(File.read(path))
    expect(record["providers"].map { it["name"] }).to eq(["old", *names])
    expect(record["rewrites"]).to eq("rewrite_9" => "old", "rewrite_1" => names[1])
  end
end
