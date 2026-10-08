# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/fake_llm"

# The router and its sessions (DESIGN.md, "Several LLM providers": Asks,
# units, and sessions; Routing; Accounting; Progress and failure messages).
# Each provider is a real LLM::Client over its own FakeLLM, with no adapter
# retries, so one scripted error is one failed ask.
RSpec.describe Quaack::Driver::LLM::Router do
  let(:names) { %w[a b c] }
  let(:fakes) { names.to_h { [it, FakeLLM.new] } }
  let(:routing) { nil }
  let(:notes) { [] }
  let(:messages) { [{ role: "user", content: "Propose rewrites for this shape." }] }

  let(:providers) do
    config = { "llms" => names.map { { "name" => it, "provider" => "anthropic" } } }
    config["llm_routing"] = routing if routing
    Quaack::Driver::LLM.providers(config, env: {})
  end

  let(:router) do
    clients = names.map { fakes.fetch(it).client(burndown: Quaack::Driver::Burndown.new, max_retries: 0) }
    described_class.for(providers, clients).tap do |router|
      seen = notes
      router.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
    end
  end

  def ask(on = router, step = "llm-rewrites") = on.ask(step:, messages:, max_tokens: 100)

  # The provider each ask went to, in order, across every fake.
  def asked
    fakes.flat_map { |name, fake| fake.asks.map { [name, it] } }
  end

  # The LLM::Error the block raises. Fails the spec if it raises nothing.
  def llm_error
    yield
    raise "expected an LLM::Error"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  describe "sessions" do
    it "keeps every ask of a unit on the provider its first ask went to" do
      fakes["a"].reply("llm-index-ideas", "one").reply("llm-index-ideas", "two")
      fakes["b"].reply("llm-rewrites", "other")
      session = router.session

      expect([ask(session, "llm-index-ideas"), ask, ask(session, "llm-index-ideas")]).to eq(%w[one other two])
      expect(fakes["a"].asks.map(&:step)).to eq(%w[llm-index-ideas llm-index-ideas])
      expect(session.provider).to eq("a")
    end

    it "makes each ask on the router itself a unit of one" do
      fakes["a"].reply("llm-rewrites", "1")
      fakes["b"].reply("llm-rewrites", "2")

      expect([ask, ask]).to eq(%w[1 2])
    end
  end

  describe "round_robin, the default" do
    it "starts each unit on the next provider after the one the last unit started on" do
      %w[a b c].each { fakes[it].reply("llm-rewrites", it).reply("llm-rewrites", it) }

      expect(Array.new(5) { ask }).to eq(%w[a b c a b])
    end

    context "with a pinned step" do
      let(:routing) { { "steps" => { "llm-counterexamples" => { "providers" => %w[c b] } } } }

      it "turns one cursor across the whole list, skipping providers outside the pool" do
        fakes["a"].reply("llm-rewrites", "a")
        fakes["b"].reply("llm-counterexamples", "b")
        fakes["c"].reply("llm-rewrites", "c")

        expect([ask, ask(router, "llm-counterexamples"), ask]).to eq(%w[a b c])
      end
    end
  end

  describe "failover" do
    let(:routing) { { "mode" => "failover" } }

    it "starts every unit on the pool's first healthy provider" do
      3.times { fakes["a"].reply("llm-rewrites", "a") }

      expect(Array.new(3) { ask }).to eq(%w[a a a])
    end

    context "as one step's own mode" do
      let(:routing) { { "steps" => { "llm-rewrites" => { "mode" => "failover", "providers" => %w[b c] } } } }

      it "starts on the pinned pool's first provider, in its order" do
        2.times { fakes["b"].reply("llm-rewrites", "b") }

        expect([ask, ask]).to eq(%w[b b])
      end
    end
  end

  describe "a unit's first ask that fails" do
    let(:routing) { { "mode" => "failover" } }

    it "marks a rate-limited provider down and starts the unit again on the next one" do
      fakes["a"].error("llm-rewrites", status: 429)
      2.times { fakes["b"].reply("llm-rewrites", "b") }

      expect([ask, ask]).to eq(%w[b b])
      expect(fakes["a"].asks.size).to eq(1)
      expect(notes).to include("a is rate limited, so the rest of this run skips it; trying b (llm-rewrites)")
    end

    it "marks an unavailable provider down too" do
      fakes["a"].error("llm-rewrites", status: 529)
      2.times { fakes["b"].reply("llm-rewrites", "b") }

      expect([ask, ask]).to eq(%w[b b])
      expect(notes).to include("a is unavailable, so the rest of this run skips it; trying b (llm-rewrites)")
    end

    it "drops a provider whose credentials were refused, saying so loudly" do
      fakes["a"].error("llm-rewrites", status: 401)
      2.times { fakes["b"].reply("llm-rewrites", "b") }

      expect([ask, ask]).to eq(%w[b b])
      expect(notes).to include("llm_auth: a: the API refused the credentials, so the rest of this run skips a. " \
                               "Fix its credentials before the next run. Trying b (llm-rewrites)")
    end

    context "when the dropped provider is a copilot command" do
      let(:providers) do
        Quaack::Driver::LLM.providers({ "llms" => [{ "name" => "a", "provider" => "copilot_cli" },
                                                   { "name" => "b", "provider" => "anthropic" },
                                                   { "name" => "c", "provider" => "anthropic" }],
                                        "llm_routing" => routing }, env: {})
      end

      it "says the command isn't logged in" do
        fakes["a"].error("llm-rewrites", status: 401)
        fakes["b"].reply("llm-rewrites", "b")

        expect(ask).to eq("b")
        expect(notes).to include("llm_auth: a: the copilot command said it isn't logged in, so the rest of this " \
                                 "run skips a. Fix its credentials before the next run. Trying b (llm-rewrites)")
      end
    end

    it "moves on from a reply that couldn't be used without marking the provider down" do
      fakes["a"].cut_short("llm-rewrites", "par").reply("llm-rewrites", "a")
      fakes["b"].reply("llm-rewrites", "b")

      expect([ask, ask]).to eq(%w[b a])
      expect(notes).to include("a's reply couldn't be used, though later asks may still use it; " \
                               "trying b (llm-rewrites)")
    end

    it "fails the step on llm_bad_request, naming the provider, and tries no other" do
      fakes["a"].error("llm-rewrites", status: 400, message: "unknown model")

      error = llm_error { ask }
      expect(error.rule).to eq("llm_bad_request")
      expect(error.message).to start_with("llm_bad_request: a: ").and include("unknown model")
      expect(asked.map(&:first)).to eq(["a"])
    end

    it "fails the step with the last rule and what was tried when no provider is left" do
      fakes["a"].error("llm-rewrites", status: 429)
      fakes["b"].cut_short("llm-rewrites", "par")
      fakes["c"].error("llm-rewrites", status: 529)

      error = llm_error { ask }
      expect(error.rule).to eq("llm_unavailable")
      expect(error.message).to eq("llm_unavailable: every LLM provider llm-rewrites may use failed: " \
                                  "a (llm_rate_limited), b (llm_bad_response), c (llm_unavailable). " \
                                  "[step llm-rewrites, max_tokens 100, system 0 chars, messages: user 32]")
    end

    it "fails a later unit at once when every provider in its pool is down, listing why" do
      fakes["a"].error("llm-rewrites", status: 429)
      fakes["b"].error("llm-rewrites", status: 401)
      fakes["c"].error("llm-rewrites", status: 529)
      llm_error { ask }

      error = llm_error { ask(router, "llm-index-ideas") }
      expect([error.rule, sans_sizes(error.message)])
        .to eq(["llm_unavailable", "llm_unavailable: every LLM provider llm-index-ideas may use failed: " \
                                   "a (llm_rate_limited), b (llm_auth), c (llm_unavailable)."])
      expect(asked.size).to eq(3)
    end
  end

  describe "a later ask in a unit that fails" do
    let(:routing) { { "mode" => "failover" } }

    it "fails the step, naming the provider, and marks it down for later units" do
      fakes["a"].reply("llm-index-ideas", "first").error("llm-index-ideas", status: 429)
      fakes["b"].reply("llm-rewrites", "b")
      session = router.session
      ask(session, "llm-index-ideas")

      error = llm_error { ask(session, "llm-index-ideas") }
      expect(error.rule).to eq("llm_rate_limited")
      expect(error.message).to start_with("llm_rate_limited: a: ").and include("fake rate_limit_error")
      expect(fakes["b"].asks).to eq([])
      expect(ask).to eq("b")
    end

    it "doesn't mark the provider down for a reply that couldn't be used" do
      fakes["a"].reply("llm-index-ideas", "first").cut_short("llm-index-ideas", "par").reply("llm-rewrites", "a")
      session = router.session
      ask(session, "llm-index-ideas")

      expect(llm_error { ask(session, "llm-index-ideas") }.rule).to eq("llm_bad_response")
      expect(ask).to eq("a")
    end
  end

  describe "accounting and progress" do
    it "counts every attempt under its step and its provider, a failed-over unit's on each provider it tried" do
      fakes["a"].error("llm-rewrites", status: 429)
      fakes["b"].reply("llm-rewrites", "b").reply("llm-index-ideas", "b")
      ask
      ask(router, "llm-index-ideas")

      expect(router.burndown.llm_calls).to eq("llm-rewrites" => 2, "llm-index-ideas" => 1)
      expect(router.burndown.llm_calls_by_provider)
        .to eq("a" => { "llm-rewrites" => 1 }, "b" => { "llm-rewrites" => 1, "llm-index-ideas" => 1 })
    end

    it "names the provider in each ask's progress line" do
      fakes["a"].reply("llm-rewrites", "a")
      fakes["b"].reply("llm-rewrites", "b")
      ask
      ask

      expect(notes).to eq(["Asking the LLM (llm-rewrites, a)", "Asking the LLM (llm-rewrites, b)"])
    end
  end

  describe "the trust boundary" do
    let(:names) { %w[sentinel-name-one sentinel-name-two] }

    # Every request body sent to any provider, as JSON text.
    def sent = fakes.values.flat_map(&:asks).map { JSON.generate(it.body) }.join("\n")

    it "never puts a provider's name in any prompt, across a failover and a session's later ask" do
      fakes["sentinel-name-one"].error("llm-index-ideas", status: 429)
      fakes["sentinel-name-two"].reply("llm-index-ideas", "1").reply("llm-index-ideas", "2")
      session = router.session
      2.times { ask(session, "llm-index-ideas") }

      expect(fakes.values.sum { it.asks.size }).to eq(3)
      expect(sent).not_to include("sentinel")
      expect(notes.join).to include("sentinel-name-one", "sentinel-name-two")
    end

    it "would catch a name planted in a prompt" do
      fakes["sentinel-name-one"].reply("llm-rewrites", "ok")
      router.ask(step: "llm-rewrites", messages: [{ role: "user", content: "from sentinel-name-one" }], max_tokens: 10)

      expect(sent).to include("sentinel")
    end
  end

  describe "one provider from an llm block, or none" do
    let(:fake) { FakeLLM.new }
    let(:router) do
      providers = Quaack::Driver::LLM.providers(nil, env: {})
      described_class.for(providers, [fake.client(burndown: Quaack::Driver::Burndown.new, max_retries: 0)]).tap do |r|
        seen = notes
        r.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
      end
    end

    it "names no provider in its lines, though it counts under it" do
      fake.reply("llm-rewrites", "ok")

      expect(ask).to eq("ok")
      expect(notes).to eq(["Asking the LLM (llm-rewrites)"])
      expect(router.burndown.llm_calls_by_provider).to eq("anthropic" => { "llm-rewrites" => 1 })
    end

    it "fails as the client does, with the provider's own detail" do
      fake.error("llm-rewrites", status: 429, message: "slow down")

      error = llm_error { ask }
      expect(error.rule).to eq("llm_rate_limited")
      expect(error.message).to start_with("llm_rate_limited: ").and include("slow down")
      expect(error.message).not_to include("anthropic:")
      expect(error.message).not_to include("every LLM provider")
    end

    it "is what Router.one builds around a lone client" do
      fake.reply("llm-rewrites", "ok")
      one = described_class.one(fake.client(burndown: Quaack::Driver::Burndown.new))

      expect(ask(one)).to eq("ok")
      expect(one.burndown.llm_calls_by_provider).to eq("anthropic" => { "llm-rewrites" => 1 })
    end
  end
end
