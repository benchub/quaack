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

  describe "what it tells the provenance record" do
    let(:routing) { { "mode" => "failover" } }

    it "lists each entry's name, provider type, and model, in order" do
      expected = names.map { { "name" => it, "provider" => "anthropic", "model" => "claude-opus-5-5" } }
      expect(router.entries).to eq(expected)
    end

    it "lists each provider it marked down or dropped, by rule, and none it only moved on from" do
      fakes["a"].error("llm-rewrites", status: 401)
      fakes["b"].raw("llm-rewrites", "[1]")
      fakes["c"].reply("llm-rewrites", "c")
      fakes["b"].error("llm-rewrites", status: 429)
      fakes["c"].reply("llm-rewrites", "c")

      ask
      expect(router.down).to eq("a" => "llm_auth")
      ask
      expect(router.down).to eq("a" => "llm_auth", "b" => "llm_rate_limited")
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

    it "raises a LaterError naming the provider and step, so the step can go on without it" do
      fakes["a"].reply("llm-index-ideas", "first").error("llm-index-ideas", status: 503)
      session = router.session
      ask(session, "llm-index-ideas")

      error = llm_error { ask(session, "llm-index-ideas") }
      expect(error).to be_a(Quaack::Driver::LLM::Router::LaterError)
      expect([error.rule, error.provider, error.step]).to eq(%w[llm_unavailable a llm-index-ideas])
      expect(session.failures.transform_values(&:rule)).to eq("a" => "llm_unavailable")
    end

    it "raises a plain error for llm_bad_request, which fails the step" do
      fakes["a"].reply("llm-index-ideas", "first").error("llm-index-ideas", status: 400)
      session = router.session
      ask(session, "llm-index-ideas")

      error = llm_error { ask(session, "llm-index-ideas") }
      expect(error).not_to be_a(Quaack::Driver::LLM::Router::LaterError)
      expect(error.message).to start_with("llm_bad_request: a: ")
    end

    it "says the step goes on without the provider, by the rule" do
      fakes["a"].reply("llm-index-ideas", "1").error("llm-index-ideas", status: 429)
      fakes["b"].reply("llm-index-ideas", "2").cut_short("llm-index-ideas", "par")
                .reply("llm-index-ideas", "3").error("llm-index-ideas", status: 401)
      3.times do
        session = router.session
        ask(session, "llm-index-ideas")
        router.going_on(llm_error { ask(session, "llm-index-ideas") }, "going on without replacement ideas")
      end

      expect(notes.grep_v(/\AAsking/))
        .to eq(["a is rate limited, so the rest of this run skips it; going on without replacement ideas " \
                "(llm-index-ideas)",
                "b's reply couldn't be used, though later asks may still use it; going on without replacement " \
                "ideas (llm-index-ideas)",
                "llm_auth: b: the API refused the credentials, so the rest of this run skips b. Fix its " \
                "credentials before the next run. Going on without replacement ideas (llm-index-ideas)"])
    end
  end

  describe "a unit started fresh after a later ask failed" do
    let(:routing) { { "mode" => "failover" } }

    # The LaterError of a's unit, whose second ask fails as fail does.
    def later_failure(fail)
      fakes["a"].reply("llm-counterexamples", "first")
      fail.call(fakes["a"])
      session = router.session
      ask(session, "llm-counterexamples")
      llm_error { ask(session, "llm-counterexamples") }.then { [it, session] }
    end

    it "skips the providers it's told to, though not down, and says it's starting fresh" do
      error, session = later_failure(->(a) { a.cut_short("llm-counterexamples", "par") })
      fakes["b"].reply("llm-counterexamples", "fresh")
      fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox")

      expect(ask(fresh, "llm-counterexamples")).to eq("fresh")
      expect(fresh.provider).to eq("b")
      expect(notes.last(2))
        .to eq(["a's reply couldn't be used, though later asks may still use it; asking b for the remaining rounds, " \
                "starting fresh (llm-counterexamples, Rewrite Silver Fox)",
                "Asking the LLM (llm-counterexamples, b)"])
    end

    it "fails over at its first ask as any unit does, and its failures name every provider it failed on" do
      error, session = later_failure(->(a) { a.error("llm-counterexamples", status: 401) })
      fakes["b"].error("llm-counterexamples", status: 503)
      fakes["c"].reply("llm-counterexamples", "fresh")
      fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox")

      expect(ask(fresh, "llm-counterexamples")).to eq("fresh")
      expect(notes.grep_v(/\AAsking/))
        .to eq(["llm_auth: a: the API refused the credentials, so the rest of this run skips a. Fix its credentials " \
                "before the next run. Asking b for the remaining rounds, starting fresh (llm-counterexamples, " \
                "Rewrite Silver Fox)",
                "b is unavailable, so the rest of this run skips it; trying c (llm-counterexamples)"])
      expect(fresh.failures.transform_values(&:rule)).to eq("b" => "llm_unavailable")
    end

    context "when every other provider is down" do
      let(:routing) { { "mode" => "failover", "steps" => { "llm-rewrites" => { "providers" => %w[b c] } } } }

      it "fails the step with the later failure's rule, listing what was tried" do
        error, session = later_failure(->(a) { a.cut_short("llm-counterexamples", "par") })
        fakes["b"].error("llm-rewrites", status: 429)
        fakes["c"].error("llm-rewrites", status: 429)
        llm_error { ask }
        notes.clear
        fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox")

        failure = llm_error { ask(fresh, "llm-counterexamples") }
        expect(failure.rule).to eq("llm_bad_response")
        expect(failure.message)
          .to start_with("llm_bad_response: every LLM provider llm-counterexamples may use failed: " \
                         "b (llm_rate_limited), c (llm_rate_limited), a (llm_bad_response).")
        expect(notes).to eq([])
      end
    end
  end

  # DESIGN.md, "Several LLM providers" (Adversarial pairing): a and c
  # share a model, so either counts as the author of a rewrite a wrote.
  describe "adversarial pairing" do
    let(:models) { { "a" => "model-one", "b" => "model-two", "c" => "model-one" } }
    let(:pairing) { "prefer_different" }
    let(:routing) do
      { "mode" => "failover", "counterexample_pairing" => pairing,
        "steps" => { "llm-index-refine" => { "providers" => ["b"] } } }
    end

    # Marks b down, by a failed llm-index-refine unit, pinned to b.
    def b_down(status)
      fakes["b"].error("llm-index-refine", status:)
      llm_error { ask(router, "llm-index-refine") }
    end
    let(:providers) do
      config = { "llms" => names.map { { "name" => it, "provider" => "anthropic", "model" => models[it] } },
                 "llm_routing" => routing }
      Quaack::Driver::LLM.providers(config, env: {})
    end
    let(:author) { { "name" => "a", "provider" => "anthropic", "model" => "model-one" } }

    def paired(author = self.author) = router.session(pairing: router.pairing(author, label: "Rewrite Silver Fox"))

    def counter(session) = ask(session, "llm-counterexamples")

    it "keeps the unit off the author and every entry with its model, and says the pairing was met" do
      fakes["b"].reply("llm-counterexamples", "paired")
      session = paired

      expect(counter(session)).to eq("paired")
      expect([session.provider, session.pairing]).to eq(%w[b met])
      expect(fakes["a"].asks).to eq([])
    end

    it "counts the entry that wrote the rewrite as its author, though its model has changed since" do
      fakes["b"].reply("llm-counterexamples", "paired")
      session = paired({ "name" => "a", "provider" => "anthropic", "model" => "an-older-model" })

      expect([counter(session), session.provider, session.pairing]).to eq(%w[paired b met])
    end

    it "starts a round_robin unit on the next provider it may use, and turns the cursor to it" do
      routing.delete("mode")
      fakes["b"].reply("llm-counterexamples", "paired")
      fakes["c"].reply("llm-rewrites", "next")
      session = paired

      expect([counter(session), session.provider, ask]).to eq(%w[paired b next])
    end

    context "with prefer_different" do
      it "falls back to the author when every other provider fails, and says the pairing wasn't met" do
        fakes["b"].error("llm-counterexamples", status: 429)
        fakes["a"].reply("llm-counterexamples", "own")
        session = paired

        expect([counter(session), session.provider, session.pairing]).to eq(%w[own a not_met])
      end

      it "uses the author when no other provider is healthy at the start" do
        b_down(429)
        fakes["a"].reply("llm-counterexamples", "own")
        session = paired

        expect([counter(session), session.provider, session.pairing]).to eq(%w[own a not_met])
      end
    end

    context "with require_different" do
      let(:pairing) { "require_different" }

      it "fails the step as llm_unavailable, naming the rewrite and its author, when every other provider fails" do
        fakes["b"].error("llm-counterexamples", status: 429)
        failure = llm_error { counter(paired) }

        expect(failure.rule).to eq("llm_unavailable")
        expect(failure.message)
          .to eq("llm_unavailable: llm-counterexamples: Rewrite Silver Fox was written by a, and " \
                 "counterexample_pairing is require_different, but no provider it may use is left that didn't " \
                 "write it or share its model: b (llm_rate_limited)")
        expect([fakes["a"].asks, fakes["c"].asks]).to eq([[], []])
      end

      it "fails at once when no other provider is healthy at the start" do
        b_down(503)
        failure = llm_error { counter(paired) }

        expect(failure.message).to end_with("share its model: b (llm_unavailable)")
        expect(fakes["a"].asks).to eq([])
      end
    end

    context "with any" do
      let(:pairing) { "any" }

      it "picks as for any other step, and says pairing doesn't apply" do
        fakes["a"].reply("llm-counterexamples", "own")
        session = paired

        expect([counter(session), session.provider, session.pairing]).to eq(%w[own a not_applicable])
      end
    end

    it "picks as with any when the rewrite's author wasn't recorded, and says the pairing couldn't be checked" do
      fakes["a"].reply("llm-counterexamples", "own")
      session = paired(nil)

      expect([counter(session), session.provider, session.pairing]).to eq(%w[own a unchecked])
    end

    it "keeps a fresh start off the author too" do
      by_b = { "name" => "b", "provider" => "anthropic", "model" => "model-two" }
      fakes["a"].reply("llm-counterexamples", "first").cut_short("llm-counterexamples", "par")
      fakes["c"].reply("llm-counterexamples", "fresh")
      session = paired(by_b)
      counter(session)
      error = llm_error { counter(session) }
      fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox",
                                  pairing: router.pairing(by_b, label: "Rewrite Silver Fox"))

      expect([counter(fresh), fresh.provider, fresh.pairing]).to eq(%w[fresh c met])
      expect(fakes["b"].asks).to eq([])
    end

    it "leaves a session without pairing as it was" do
      fakes["a"].reply("llm-counterexamples", "plain")
      session = router.session

      expect([counter(session), session.provider, session.pairing]).to eq(["plain", "a", nil])
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
    let(:models) { names.to_h { [it, "sentinel-model-#{it.delete_prefix("sentinel-name-")}"] } }
    let(:routing) { { "mode" => "failover" } }

    let(:providers) do
      config = { "llms" => names.map { { "name" => it, "provider" => "anthropic", "model" => models[it] } },
                 "llm_routing" => routing }
      Quaack::Driver::LLM.providers(config, env: {})
    end

    let(:router) do
      clients = names.map do |name|
        fakes.fetch(name).client(burndown: Quaack::Driver::Burndown.new, max_retries: 0, model: models[name])
      end
      described_class.for(providers, clients).tap do |router|
        seen = notes
        router.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
      end
    end

    # Every prompt sent to any provider, its system prompt and messages, as
    # JSON text. The request's own model field isn't a prompt.
    def sent = fakes.values.flat_map(&:asks).map { JSON.generate([it.body[:system], it.body[:messages]]) }.join("\n")

    it "sends each request to its entry's model, which is a sentinel" do
      fakes["sentinel-name-one"].reply("llm-rewrites", "ok")
      ask

      expect(fakes["sentinel-name-one"].asks.first.body[:model]).to eq("sentinel-model-one")
    end

    it "never puts a provider's name or model in a fresh start's prompt" do
      fakes["sentinel-name-one"].reply("llm-counterexamples", "1").error("llm-counterexamples", status: 429)
      fakes["sentinel-name-two"].reply("llm-counterexamples", "2").reply("llm-counterexamples", "3")
      session = router.session
      ask(session, "llm-counterexamples")
      error = llm_error { ask(session, "llm-counterexamples") }
      fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox")
      2.times { ask(fresh, "llm-counterexamples") }

      expect(fakes.values.sum { it.asks.size }).to eq(4)
      expect(sent).not_to include("sentinel")
      expect(notes.join).to include("sentinel-name-one", "sentinel-name-two")
    end

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

    it "would catch a model planted in a prompt" do
      fakes["sentinel-name-one"].reply("llm-rewrites", "ok")
      router.ask(step: "llm-rewrites", system: "you are sentinel-model-one", messages:, max_tokens: 10)

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

    it "fails a fresh start with the later failure itself, since no provider is left" do
      fake.reply("llm-counterexamples", "first").error("llm-counterexamples", status: 429, message: "slow down")
      session = router.session
      ask(session, "llm-counterexamples")
      error = llm_error { ask(session, "llm-counterexamples") }
      fresh = router.fresh(error, skip: session.failures, label: "Rewrite Silver Fox")

      failure = llm_error { ask(fresh, "llm-counterexamples") }
      expect(failure.rule).to eq("llm_rate_limited")
      expect(failure.message).to start_with("llm_rate_limited: ").and include("slow down")
      expect(failure.message).not_to include("anthropic:", "every LLM provider")
      expect(fake.asks.size).to eq(2)
    end

    # The replacement round's failure skips the round, so the next unit,
    # with no provider left, fails as the run did before the round was
    # skipped: with the API's own detail, and no list. llm_auth's detail is
    # the client's own words, not the API's.
    { 429 => "retry in 30s", 503 => "retry in 30s", 401 => "refused the key" }.each do |status, detail|
      it "fails the next unit with the skipped round's own failure after a #{status}" do
        fake.reply("llm-index-ideas", "1").error("llm-index-ideas", status:, message: "retry in 30s")
        session = router.session
        ask(session, "llm-index-ideas")
        later = llm_error { ask(session, "llm-index-ideas") }
        router.going_on(later, "going on without replacement ideas")

        failure = llm_error { ask(router, "llm-index-refine") }
        expect(failure.rule).to eq(later.rule)
        expect(failure.message).to eq(later.message).and include(detail)
        expect(failure.message).not_to include("anthropic:", "anthropic (", "every LLM provider")
        expect(fake.asks.size).to eq(2)
      end
    end

    {
      429 => "The LLM is rate limited, so the rest of this run skips it; going on without replacement ideas " \
             "(llm-index-ideas)",
      401 => "llm_auth: the API refused the credentials, so the rest of this run skips the LLM. Fix its " \
             "credentials before the next run. Going on without replacement ideas (llm-index-ideas)"
    }.each do |status, line|
      it "names no provider when the step goes on without it after a #{status}" do
        fake.reply("llm-index-ideas", "1").error("llm-index-ideas", status:)
        session = router.session
        ask(session, "llm-index-ideas")
        router.going_on(llm_error { ask(session, "llm-index-ideas") }, "going on without replacement ideas")

        expect(notes.last).to eq(line)
      end
    end

    it "is what Router.one builds around a lone client" do
      fake.reply("llm-rewrites", "ok")
      one = described_class.one(fake.client(burndown: Quaack::Driver::Burndown.new))

      expect(ask(one)).to eq("ok")
      expect(one.burndown.llm_calls_by_provider).to eq("anthropic" => { "llm-rewrites" => 1 })
    end
  end
end
