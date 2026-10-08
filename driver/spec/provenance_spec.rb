# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/provenance"
require "quaack/driver/refinement_round"

RSpec.describe Quaack::Driver::Provenance do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      example.run
    end
  end

  let(:run_id) { "20261008T120000Z-0123abcd" }
  let(:path) { File.join(@home, ".quaack", "runs", "#{run_id}.llm.json") }
  let(:provenance) { described_class.open(@home, run_id) }

  def saved = JSON.parse(File.read(path))

  def outcome(index, outcome, rule = nil)
    { "type" => "index_outcome", "index" => index, "outcome" => outcome,
      "rule" => rule }
  end

  it "writes ~/.quaack/runs/<run ID>.llm.json, mode 0600, in a 0700 runs directory" do
    old = File.umask(0o000)
    begin
      provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
      provenance.save
    ensure
      File.umask(old)
    end

    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    expect(saved["providers"]).to eq([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
  end

  it "writes the record whole to a temporary file and renames it into place, leaving nothing else" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
    provenance.save
    before = File.stat(path).ino
    provenance.operator_inference!("groq")
    provenance.save

    expect(File.stat(path).ino).not_to eq(before)
    expect(Dir.children(File.dirname(path))).to eq(["#{run_id}.llm.json"])
    expect(saved["operator_inference"]).to eq("groq")
  end

  it "records each rewrite's author by store name, and how many each entry proposed" do
    outcomes = [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rewrite" => "rewrite_3" },
                { "type" => "rewrite_outcome", "index" => 2, "outcome" => "rejected", "rule" => "too_many",
                  "rewrite" => nil },
                { "type" => "rewrite_outcome", "index" => 3, "outcome" => "accepted", "rewrite" => "rewrite_4" }]
    provenance.rewrites!(outcomes, entries: %w[groq groq groq], branches: %w[groq])
    provenance.save

    expect(saved["rewrites"]).to eq("rewrite_3" => "groq", "rewrite_4" => "groq")
    expect(saved["rewrites_proposed"]).to eq("groq" => 3)
  end

  # DESIGN.md, "Several LLM providers" (Provenance): a fan-out step's
  # outcomes map back to their branches by position in the input.
  it "maps a fan-out union's outcomes to the entry that wrote each, by its position, and counts each branch" do
    outcomes = [{ "type" => "rewrite_outcome", "index" => 3, "outcome" => "accepted", "rewrite" => "rewrite_7" },
                { "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rewrite" => "rewrite_5" },
                { "type" => "rewrite_outcome", "index" => 2, "outcome" => "accepted", "rewrite" => "rewrite_6" },
                { "type" => "rewrite_outcome", "index" => 4, "outcome" => "rejected", "rewrite" => nil }]
    provenance.rewrites!(outcomes, entries: %w[groq opus opus groq], branches: %w[groq opus gpt])
    provenance.save

    expect(saved["rewrites"]).to eq("rewrite_5" => "groq", "rewrite_6" => "opus", "rewrite_7" => "opus")
    expect(saved["rewrites_proposed"]).to eq("groq" => 2, "opus" => 2, "gpt" => 0)
  end

  it "maps a fan-out index round's outcomes to the entry that wrote each, and records each skipped branch" do
    require "quaack/driver/generator_three"
    g3 = Quaack::Driver::GeneratorThree
    first = g3::Round.new(ddls: %w[d1 d2 d3], entries: %w[groq opus groq],
                          outcomes: [outcome(1, "accepted"), outcome(2, "dropped", "duplicate"),
                                     outcome(3, "dropped", "too_many")])
    replacement = g3::Round.new(ddls: %w[d4], entries: %w[opus], round: "replacement",
                                outcomes: [outcome(1, "set_aside")])
    provenance.index_ideas!("original", g3::Result.new(rounds: [first, replacement], providers: %w[groq opus gpt],
                                                       skipped: { "groq" => "llm_unavailable" }))
    provenance.save

    tally = ->(written, outcomes, rules = {}) { { "written" => written, "outcomes" => outcomes, "rules" => rules } }
    expect(saved["index_ideas"]["original"]).to eq(
      "first" => { "groq" => tally.call(2, { "accepted" => 1, "dropped" => 1 }, { "too_many" => 1 }),
                   "opus" => tally.call(1, { "dropped" => 1 }, { "duplicate" => 1 }), "gpt" => tally.call(0, {}) },
      "replacement" => { "opus" => tally.call(1, { "set_aside" => 1 }) },
      "skipped" => [{ "entry" => "groq", "rule" => "llm_unavailable" }]
    )
  end

  it "records each entry that ran a rewrite's counterexample rounds, in order, with the rule before a fresh start" do
    provenance.counterexamples!("rewrite_2", [{ "entry" => "groq", "rounds" => 1 },
                                              { "entry" => "opus", "rounds" => 2, "after" => "llm_rate_limited" }])
    provenance.save

    expect(saved["counterexamples"]).to eq(
      "rewrite_2" => [{ "entry" => "groq", "rounds" => 1 },
                      { "entry" => "opus", "rounds" => 2, "after" => "llm_rate_limited" }]
    )
  end

  it "records each unit's pairing outcome, of the four, and reads back only those" do
    outcomes = %w[met not_met not_applicable unchecked]
    outcomes.each_with_index do |pairing, i|
      provenance.counterexamples!("rewrite_#{i + 1}", [{ "entry" => "groq", "rounds" => 1, "pairing" => pairing }])
    end
    provenance.counterexamples!("rewrite_9", [{ "entry" => "groq", "rounds" => 1, "pairing" => "SELECT 1" }])
    provenance.save

    expect(saved["counterexamples"].transform_values { it.first["pairing"] })
      .to eq(outcomes.each_with_index.to_h { |pairing, i| ["rewrite_#{i + 1}", pairing] })
    expect(described_class.open(@home, run_id).record["counterexamples"].keys).to eq(%w[rewrite_1 rewrite_2 rewrite_3
                                                                                        rewrite_4])
  end

  it "counts each index round's statements and outcomes by entry, and each skipped replacement round" do
    provenance.index_round!("original", "first", "groq", 3,
                            [outcome(1, "accepted"), outcome(2, "dropped", "duplicate"), outcome(3, "set_aside")])
    provenance.index_round!("rewrite_2", "refinement", "opus", 1, [outcome(1, "dropped", "covered_by_existing")])
    provenance.skipped!("original", "groq", "llm_unavailable")
    provenance.save

    expect(saved["index_ideas"]).to eq(
      "original" => { "first" => { "groq" => { "written" => 3,
                                               "outcomes" => { "accepted" => 1, "dropped" => 1, "set_aside" => 1 },
                                               "rules" => { "duplicate" => 1 } } },
                      "skipped" => [{ "entry" => "groq", "rule" => "llm_unavailable" }] },
      "rewrite_2" => { "refinement" => { "opus" => { "written" => 1, "outcomes" => { "dropped" => 1 },
                                                     "rules" => { "covered_by_existing" => 1 } } } }
    )
  end

  it "records which providers the run marked down or dropped, by rule" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" },
                           { "name" => "opus", "provider" => "anthropic", "model" => "claude-opus-5-5" }])
    provenance.down!("groq" => "llm_auth")
    provenance.save

    expect(saved["providers"].map { it["down"] }).to eq(["llm_auth", nil])
  end

  # DESIGN.md, "Several LLM providers" (Routing, Provenance).
  it "records each failed fan-out branch's step, entry, and rule once, keeping them across a resume" do
    groq = { "step" => "llm-rewrites", "entry" => "groq", "rule" => "llm_rate_limited" }
    opus = { "step" => "llm-index-ideas", "entry" => "opus", "rule" => "llm_bad_response" }
    gpt = { "step" => "rewrite-llm-index-ideas", "entry" => "gpt", "rule" => "llm_auth" }
    provenance.failed_branches!([groq]).failed_branches!([groq, opus]).save
    described_class.open(@home, run_id).failed_branches!([opus, gpt]).save

    expect(saved["failed_branches"]).to eq([groq, opus, gpt])
  end

  it "keeps a failed branch only with a fan-out step, an entry's name, and a rule that fails over" do
    good = { "step" => "llm-rewrites", "entry" => "groq", "rule" => "llm_unavailable" }
    provenance.failed_branches!([good, good.merge("step" => "llm-counterexamples"), good.merge("entry" => "Bad Name"),
                                 good.merge("rule" => "llm_bad_request"), good.merge("reason" => "SELECT 1"),
                                 good.merge("rule" => nil), "llm-rewrites"]).save

    expect(saved["failed_branches"]).to eq([good])
  end

  it "fails over, and fans out, by the router's own lists" do
    require "quaack/driver/llm"
    expect([described_class::Shape::FAILS_OVER, described_class::Shape::FAN_OUT_STEPS])
      .to eq([Quaack::Driver::LLM::Router::FAILS_OVER, Quaack::Driver::LLM::RoutingChecks::FAN_OUT_STEPS])
  end

  it "keeps the record across a resume, adding new entries and keeping the old ones" do
    provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
    provenance.rewrites!([{ "index" => 1, "outcome" => "accepted", "rewrite" => "rewrite_1" }], entries: %w[groq])
    provenance.save

    resumed = described_class.open(@home, run_id)
    resumed.providers!([{ "name" => "opus", "provider" => "anthropic", "model" => "claude-opus-5-5" }])
    resumed.save

    expect(saved["providers"].map { it["name"] }).to eq(%w[groq opus])
    expect(saved["rewrites"]).to eq("rewrite_1" => "groq")
    expect(resumed.author("rewrite_1")).to eq("name" => "groq", "provider" => "openai_compatible",
                                              "model" => "llama")
  end

  it "reads as empty when there's no record, and says nothing of what it lacks" do
    expect(provenance.record).to eq({})
    expect(provenance.author("rewrite_1")).to be_nil
  end

  it "keeps only well-formed parts of a record it reads, so nothing else reaches the report" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       "providers" => [{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" },
                                       { "name" => "Bad Name", "provider" => "anthropic", "model" => "x" },
                                       "not an object"],
                       "rewrites" => { "rewrite_1" => "groq", "SELECT 1" => "groq", "rewrite_2" => 5 },
                       "rewrites_proposed" => { "groq" => -1 },
                       "operator_inference" => ["groq"],
                       "failed_branches" => [{ "step" => "llm-rewrites", "entry" => "groq", "rule" => "llm_auth" },
                                             { "step" => "llm-rewrites", "entry" => "groq", "rule" => "llm_auth",
                                               "reason" => "SELECT secret" },
                                             { "step" => "SELECT secret", "entry" => "groq", "rule" => "llm_auth" },
                                             { "step" => "llm-rewrites", "entry" => "groq",
                                               "rule" => "SELECT_secret" },
                                             { "step" => "llm-rewrites", "entry" => "groq" }, "SELECT secret"],
                       "extra" => "SELECT secret"
                     ))

    expect(provenance.record).to eq(
      "providers" => [{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }],
      "rewrites" => { "rewrite_1" => "groq" },
      "failed_branches" => [{ "step" => "llm-rewrites", "entry" => "groq", "rule" => "llm_auth" }]
    )
  end

  it "drops a provider's down or model, a counterexample unit, an index round's counts, or a skip of a bad shape" do
    good = { "entry" => "groq", "rounds" => 1 }
    counts = { "written" => 2, "outcomes" => { "accepted" => 2 }, "rules" => { "duplicate" => 1 } }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       "providers" => [{ "name" => "groq", "provider" => "anthropic", "model" => "m",
                                         "down" => "SELECT 1" },
                                       { "name" => "opus", "provider" => "anthropic", "model" => "m\nSELECT 1" }],
                       "counterexamples" => {
                         "rewrite_1" => [good], "rewrite_2" => [good, { "entry" => "opus", "rounds" => "2" }],
                         "rewrite_3" => [{ "entry" => "groq", "rounds" => 1, "after" => "SELECT 1" }],
                         "rewrite_4" => [{ "entry" => "groq", "rounds" => 1, "sql" => "SELECT 1" }],
                         "rewrite_5" => [{ "entry" => "groq", "rounds" => 0 }],
                         "rewrite_6" => [{ "entry" => "groq", "rounds" => 4 }],
                         "rewrite_7" => [{ "entry" => "groq", "rounds" => 10**9 }],
                         "rewrite_8" => [{ "entry" => "groq", "rounds" => 1.0 }],
                         "rewrite_9" => [{ "entry" => "groq", "rounds" => 1, "pairing" => "SELECT 1" }],
                         "rewrite_10" => [{ "entry" => "groq", "rounds" => 1, "pairing" => "met" }]
                       },
                       "index_ideas" => { "original" => {
                         "first" => { "groq" => counts, "opus" => counts.merge("written" => -1),
                                      "gpt" => counts.merge("outcomes" => { "SELECT 1" => 1 }),
                                      "bad" => counts.merge("rules" => { "duplicate" => "1" }),
                                      "more" => counts.merge("ddl" => "CREATE INDEX x") },
                         "skipped" => [{ "entry" => "groq", "rule" => "llm_auth" },
                                       { "entry" => "groq", "rule" => "SELECT 1" },
                                       { "entry" => "groq", "rule" => "llm_auth", "ddl" => "CREATE INDEX x" }]
                       } }
                     ))

    expect(provenance.record).to eq(
      "providers" => [{ "name" => "groq", "provider" => "anthropic", "model" => "m" }],
      "counterexamples" => { "rewrite_1" => [good],
                             "rewrite_10" => [{ "entry" => "groq", "rounds" => 1, "pairing" => "met" }] },
      "index_ideas" => { "original" => { "first" => { "groq" => counts },
                                         "skipped" => [{ "entry" => "groq", "rule" => "llm_auth" }] } }
    )
  end

  it "caps a unit's rounds at the most a rewrite gets" do
    require "quaack/driver/counterexamples"
    expect(described_class::Shape::MOST_ROUNDS).to eq(Quaack::Driver::Counterexamples::ROUNDS)
  end

  it "reads a record that isn't JSON, or isn't an object, as empty" do
    FileUtils.mkdir_p(File.dirname(path))
    ["{", "[1]", "null"].each do |text|
      File.write(path, text)
      expect(described_class.open(@home, run_id).record).to eq({})
    end
  end

  it "refuses a run ID that isn't one, since it becomes a file name" do
    expect { described_class.open(@home, "../x") }.to raise_error(ArgumentError)
  end

  describe "the writers" do
    let(:g3) do
      require "quaack/driver/generator_three"
      Quaack::Driver::GeneratorThree
    end

    it "records the refinement round's statements and outcomes under its entry" do
      result = Quaack::Driver::RefinementRound::Result.new(
        ddls: %w[d1 d2], outcomes: [outcome(1, "accepted"), outcome(2, "dropped", "covered_by_existing")],
        provider: "opus"
      )
      provenance.refinement!("rewrite_3", result).save

      expect(saved["index_ideas"]).to eq(
        "rewrite_3" => { "refinement" => { "opus" => { "written" => 2,
                                                       "outcomes" => { "accepted" => 1, "dropped" => 1 },
                                                       "rules" => { "covered_by_existing" => 1 } } } }
      )
    end

    it "records the first round of an entry that answered, even when no entry wrote any statement" do
      provenance.index_ideas!("original", g3::Result.new(rounds: [], providers: %w[groq])).save

      expect(saved["index_ideas"]).to eq(
        "original" => { "first" => { "groq" => { "written" => 0, "outcomes" => {}, "rules" => {} } } }
      )
    end

    it "takes a search's first and replacement rounds and skips from its latest llm-index-ideas, so a rerun " \
       "repeats no skip" do
      skipped = g3::Result.new(rounds: [g3::Round.new(ddls: %w[d1], entries: %w[groq], outcomes: [])],
                               providers: %w[groq opus], skipped: { "groq" => "llm_unavailable" })
      provenance.index_ideas!("original", skipped)
      provenance.refinement!("original", Quaack::Driver::RefinementRound::Result.new(ddls: [], outcomes: [],
                                                                                     provider: "opus"))
      provenance.index_ideas!("original", skipped)
      provenance.index_ideas!("rewrite_1", g3::Result.new(rounds: [], providers: %w[opus]))
      provenance.index_ideas!("rewrite_1", g3::Result.new(rounds: [], providers: %w[groq]))
      provenance.save

      expect(saved["index_ideas"]["original"]["skipped"]).to eq([{ "entry" => "groq", "rule" => "llm_unavailable" }])
      expect(saved["index_ideas"]["original"]["refinement"].keys).to eq(%w[opus])
      expect(saved["index_ideas"]["rewrite_1"]["first"].keys).to eq(%w[groq])
    end

    it "keeps from rewrite_outcomes only store names, and from an entries list only names" do
      outcomes = [{ "index" => 1, "outcome" => "accepted", "rewrite" => "SELECT 1" },
                  { "index" => 2, "outcome" => "accepted", "rewrite" => "rewrite_2" },
                  { "index" => 3, "outcome" => "accepted", "rewrite" => "rewrite_3" }]
      provenance.rewrites!(outcomes, entries: ["groq", "groq", "Bad Name"], branches: %w[groq]).save

      expect(saved["rewrites"]).to eq("rewrite_2" => "groq")
      expect(saved["rewrites_proposed"]).to eq("groq" => 2)
    end

    it "keeps a down only when it's a rule" do
      provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
      provenance.down!("groq" => "SELECT 1").save

      expect(saved["providers"]).to eq([{ "name" => "groq", "provider" => "openai_compatible", "model" => "llama" }])
    end

    it "counts only index_outcome's own outcomes" do
      provenance.index_round!("original", "first", "groq", 2, [outcome(1, "accepted"), outcome(2, "SELECT 1")]).save

      expect(saved.dig("index_ideas", "original", "first", "groq", "outcomes")).to eq("accepted" => 1)
    end
  end

  describe "across a resume" do
    let(:groq) { { "name" => "groq", "provider" => "openai_compatible", "model" => "llama" } }

    it "keeps an entry as first recorded when the config changes its provider or model" do
      provenance.providers!([groq]).save
      described_class.open(@home, run_id)
                     .providers!([{ "name" => "groq", "provider" => "anthropic", "model" => "claude-opus-5-5" }]).save

      expect(saved["providers"]).to eq([groq])
    end

    # DESIGN.md, "Several LLM providers" (Provenance), pending the user's
    # confirmation.
    it "clears an earlier run's down for a provider this run asked without marking it down" do
      opus = { "name" => "opus", "provider" => "anthropic", "model" => "claude-opus-5-5" }
      provenance.providers!([groq, opus]).down!("groq" => "llm_rate_limited", "opus" => "llm_auth").save
      described_class.open(@home, run_id).down!({}).up!(%w[groq gpt]).save

      expect(saved["providers"]).to eq([groq, opus.merge("down" => "llm_auth")])
    end
  end

  describe "saving" do
    it "tightens a looser runs directory that's already there to 0700" do
      FileUtils.mkdir_p(File.dirname(path))
      File.chmod(0o755, File.dirname(path))
      provenance.save

      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    end

    # The temporary file's name is random. One planted at that name, here
    # a symlink, makes the save fail rather than write through it.
    it "never writes through a file already at its temporary name" do
      FileUtils.mkdir_p(File.dirname(path))
      target = File.join(@home, "target")
      File.write(target, "untouched")
      allow(SecureRandom).to receive(:hex).with(8).and_return("0123456789abcdef")
      File.symlink(target, File.join(File.dirname(path), ".#{File.basename(path)}.0123456789abcdef.tmp"))
      provenance.operator_inference!("groq")

      expect { provenance.save }.to raise_error(Errno::EEXIST)
      expect(File.read(target)).to eq("untouched")
      expect(File.exist?(path)).to be(false)
    end
  end
end
