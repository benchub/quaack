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
  let(:router) do
    config = { "llms" => names.zip(models).map do |name, model|
      { "name" => name, "provider" => "anthropic", "model" => model }
    end,
               "llm_routing" => { "mode" => "failover",
                                  "steps" => { "llm-rewrites" => { "providers" => [names[1]] } } } }
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
      "index-feedback" => [{ "type" => "index_feedback", "revise" => false, "refined" => false }],
      "rewrite-payload" => [{ "type" => "rewrite_payload", "query" => "SELECT SENTINEL_PAYLOAD" }],
      "rewrite-check" => [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rule" => nil,
                            "rewrite" => "rewrite_1", "warnings" => [] },
                          { "type" => "rewrite_outcome", "index" => 2, "outcome" => "rejected", "rule" => "too_many",
                            "rewrite" => nil, "warnings" => [] }],
      "rewrite-test" => [{ "type" => "rewrite_test", "passed" => true }],
      "counterexample-payload" => [{ "type" => "counterexample_payload", "original" => "SELECT SENTINEL_PAYLOAD" }],
      "counterexample-round" => [{ "type" => "counterexample_round", "match" => true, "rule" => nil,
                                   "covered" => [], "refused" => [{ "index" => 0, "rule" => "SENTINEL_REASON" }] }]
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

  def run
    Quaack::Driver::Pipeline.new(transport:, client: router, run_id:, home: @home).run
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

    expect(JSON.parse(File.read(path))).to eq(
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
      "counterexamples" => { "rewrite_1" => [{ "entry" => names[0], "rounds" => 1 },
                                             { "entry" => names[1], "rounds" => 2, "after" => "llm_rate_limited" }] }
    )
    expect(File.stat(path).mode & 0o777).to eq(0o600)
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

  it "keeps the record from before a resume, and adds to it" do
    File.write(File.join(@home, "x"), "")
    Quaack::Driver::Provenance.open(@home, run_id)
                              .providers!([{ "name" => "old", "provider" => "anthropic", "model" => "m" }])
                              .rewrites!("old", [{ "outcome" => "accepted", "rewrite" => "rewrite_9" }], proposed: 1)
                              .save
    script
    run

    record = JSON.parse(File.read(path))
    expect(record["providers"].map { it["name"] }).to eq(["old", *names])
    expect(record["rewrites"]).to eq("rewrite_9" => "old", "rewrite_1" => names[1])
  end
end
