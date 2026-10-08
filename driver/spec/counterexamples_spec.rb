# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/counterexamples"
require_relative "support/fake_llm"
require_relative "support/routers"

# llm-counterexamples, the driver's half: ask the LLM for shape-level inserts that should
# make a candidate and the original disagree.
RSpec.describe Quaack::Driver::Counterexamples do
  include Routers

  let(:fake) { FakeLLM.new }
  let(:client) { router_of(fake) }
  let(:payload) do
    { "original" => "SELECT o.id FROM public.orders o WHERE o.status = $1",
      "candidate" => { "sql" => "SELECT o.id FROM public.orders o WHERE lower(o.status) = $1",
                       "transformation" => "lowercases status", "assumptions" => ["status is lowercase"] },
      "placeholders" => { "$1" => "text" }, "schema" => "CREATE TABLE public.orders (id integer, status text)",
      "constraints" => ["orders_pkey PRIMARY KEY (id)"], "untested_atoms" => ["o.status = $1"] }
  end
  let(:insert) { "INSERT INTO public.orders (id, status) VALUES (1, upper($1))" }

  def user_texts(ask) = ask.body[:messages].select { it[:role] == :user }.map { it[:content] }

  it "sends the payload and returns the LLM's inserts" do
    fake.reply("llm-counterexamples", { "inserts" => [insert] })
    expect(described_class.new(client:).ask(payload)).to eq([insert])
    ask = fake.asks.first
    expect(JSON.parse(user_texts(ask).first[/```json\n(.*)\n```/m, 1])).to eq(payload)
    expect(ask.body[:output_config]).to eq(format: { type: :json_schema, schema: described_class::SCHEMA })
  end

  it "tells the LLM to use $n for the query's literals, to aim at untested atoms, and to satisfy every constraint" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("$1", "untested_atoms", "every constraint", "schema-qualif")
  end

  it "tells the LLM it may set an identity key with OVERRIDING SYSTEM VALUE (task 20260927-24)" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("OVERRIDING SYSTEM VALUE")
    expect(system).not_to include("RETURNING, or OVERRIDING")
  end

  it "tells the LLM to write fixed dates and times, not the clock (task 20261004-95)" do
    fake.reply("llm-counterexamples", { "inserts" => [] })
    described_class.new(client:).ask(payload)
    system = fake.asks.first.body[:system]
    expect(system).to include("now()", "CURRENT_DATE", "'now', 'today', 'tomorrow', or 'yesterday'",
                              "fixed dates and times")
  end

  describe "the rounds" do
    let(:outcomes) { [] }
    let(:compared) { [] }
    let(:compare) do
      lambda do |inserts|
        compared << inserts
        outcomes.shift or raise "compare called more often than scripted"
      end
    end

    def clean(covered: [], refused: []) = { "match" => true, "rule" => nil, "covered" => covered, "refused" => refused }

    def run = described_class.new(client:).run(payload, compare:)

    it "runs all three rounds when none finds a mismatch, telling the LLM how each went" do
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean(refused: [{ "index" => 0, "rule" => "insert_select" }]),
                    clean(covered: ["o.status = $1"]), clean)
      result = run
      expect(compared).to eq([["INSERT 0"], ["INSERT 1"], ["INSERT 2"]])
      expect(result.disproved).to be(false)
      expect(result.covered).to eq(["o.status = $1"])
      second = fake.asks[1].body[:messages]
      expect(second.map { it[:role] }).to eq(%i[user assistant user])
      expect(second[1][:content]).to include("INSERT 0")
      expect(second[2][:content]).to include("insert_select", "same results")
    end

    it "tells progress what each round's ask is for" do
      notes = []
      client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { notes << it } }
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean, clean, clean)
      run

      expect(notes).to eq(["Asking the LLM for rows that could break the rewrite (llm-counterexamples)",
                           "Asking the LLM again, for different rows (llm-counterexamples)",
                           "Asking the LLM again, for different rows (llm-counterexamples)"])
    end

    it "keeps a rewrite's rounds on one provider, as one unit, and starts the next rewrite's on the next" do
      other = FakeLLM.new
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      other.reply("llm-counterexamples", { "inserts" => ["INSERT b"] })
      outcomes.push(clean, clean, clean, { "match" => false, "rule" => "multiset", "covered" => [], "refused" => [] })
      router = router_over({ "a" => fake, "b" => other })
      2.times { described_class.new(client: router).run(payload, compare:) }

      expect([fake.asks.size, other.asks.size]).to eq([3, 1])
    end

    it "stops once a round disproves the candidate" do
      2.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      outcomes.push(clean, { "match" => false, "rule" => "multiset", "covered" => [], "refused" => [] })
      result = run
      expect(result.rounds.size).to eq(2)
      expect(result.disproved).to be(true)
    end
    it "keeps going after a round whose inserts failed to load, without calling it disproved" do
      3.times { |i| fake.reply("llm-counterexamples", { "inserts" => ["INSERT #{i}"] }) }
      failed = { "match" => nil, "load_failed" => true, "rule" => "insert_failed", "covered" => [], "refused" => [] }
      outcomes.push(failed, clean, clean)
      result = run
      expect(result.rounds.size).to eq(3)
      expect(result.disproved).to be(false)
      expect(fake.asks[1].body[:messages][2][:content]).to include("failed to load (insert_failed)")
    end

    # DESIGN.md, "Several LLM providers" (Routing): a later round's ask
    # that fails with a rule that fails over starts the rewrite's remaining
    # rounds fresh on another provider.
    describe "a later round that fails" do
      let(:fakes) { { "a" => fake, "b" => FakeLLM.new, "c" => FakeLLM.new } }
      let(:client) { router_over(fakes, routing: { "mode" => "failover" }, max_retries: 0) }
      let(:notes) { [] }
      let(:same) { "The accepted inserts gave both queries the same results." }

      before do
        seen = notes
        client.progress = Object.new.tap { |p| p.define_singleton_method(:note) { seen << it } }
      end

      def run = described_class.new(client:, label: "Rewrite Silver Fox").run(payload, compare:)

      def inserts(*sql) = { "inserts" => sql }

      # The fresh start's one user message, for the earlier rounds, each its
      # inserts and its feedback lines.
      def fresh_text(*rounds)
        earlier = rounds.each_with_index.map do |(sql, feedback), i|
          "Round #{i + 1}'s inserts:\n\n```json\n#{JSON.generate(inserts(*sql))}\n```\n\n#{feedback}"
        end
        "The payload:\n\n```json\n#{JSON.generate(payload)}\n```\n\n" \
          "Earlier rounds, run by another model.\n\n#{earlier.join("\n\n")}\n\n" \
          "Write a new set of inserts that tries something different from all of them. " \
          "Answer with JSON: {\"inserts\": [...]}."
      end

      it "starts the remaining rounds fresh on another provider, as one user message, and counts the rounds on" do
        fake.reply("llm-counterexamples", inserts("INSERT 0")).error("llm-counterexamples", status: 429)
        fakes["b"].reply("llm-counterexamples", inserts("INSERT 1")).reply("llm-counterexamples", inserts("INSERT 2"))
        outcomes.push(clean(refused: [{ "index" => 0, "rule" => "insert_select" }]), clean, clean)
        result = run

        expect(result.rounds.size).to eq(3)
        expect(compared).to eq([["INSERT 0"], ["INSERT 1"], ["INSERT 2"]])
        first, second = fakes["b"].asks.map { it.body[:messages] }
        expect(first).to eq([{ role: :user,
                               content: fresh_text([["INSERT 0"], "insert 1 was refused (insert_select)\n#{same}"]) }])
        expect(second.map { it[:role] }).to eq(%i[user assistant user])
        expect(fakes["b"].asks.map { it.body[:system] }).to all(eq(fake.asks.first.body[:system]))
        expect(fakes["c"].asks).to eq([])
        expect(notes).to include("a is rate limited, so the rest of this run skips it; asking b for the remaining " \
                                 "rounds, starting fresh (llm-counterexamples, Rewrite Silver Fox)")
      end

      it "starts fresh again, off every provider this rewrite's rounds failed on, with every earlier round" do
        fake.reply("llm-counterexamples", inserts("INSERT 0")).cut_short("llm-counterexamples", "par")
        fakes["b"].reply("llm-counterexamples", inserts("INSERT 1")).cut_short("llm-counterexamples", "par")
        fakes["c"].reply("llm-counterexamples", inserts("INSERT 2"))
        outcomes.push(clean, clean(covered: ["o.status = $1"]), clean)

        expect(run.rounds.size).to eq(3)
        expect(fakes["c"].asks.first.body[:messages])
          .to eq([{ role: :user, content: fresh_text([["INSERT 0"], same],
                                                     [["INSERT 1"], "#{same}\nThey exercised: o.status = $1."]) }])
        expect(fakes.transform_values { it.asks.size }).to eq("a" => 2, "b" => 2, "c" => 1)
      end

      it "gives no rewrite more than three rounds, however its rounds are split" do
        fake.reply("llm-counterexamples", inserts("INSERT 0")).reply("llm-counterexamples", inserts("INSERT 1"))
            .error("llm-counterexamples", status: 503)
        fakes["b"].reply("llm-counterexamples", inserts("INSERT 2"))
        outcomes.push(clean, clean, clean)

        expect(run.rounds.size).to eq(3)
        expect(fakes["b"].asks.size).to eq(1)
      end

      it "fails the step with the last failure's rule when no provider is left" do
        fake.reply("llm-counterexamples", inserts("INSERT")).error("llm-counterexamples", status: 429)
        %w[b c].each { fakes[it].error("llm-counterexamples", status: 429) }
        outcomes.push(clean, clean, clean)

        expect { run }.to raise_error(Quaack::Driver::LLM::Error) { |e|
          expect(e.rule).to eq("llm_rate_limited")
          expect(e.message).to include("every LLM provider llm-counterexamples may use failed: " \
                                       "a (llm_rate_limited), b (llm_rate_limited), c (llm_rate_limited)")
        }
      end

      it "fails the step on llm_bad_request, starting nothing fresh" do
        fake.reply("llm-counterexamples", inserts("INSERT 0")).error("llm-counterexamples", status: 400)
        outcomes.push(clean)

        expect { run }.to raise_error(Quaack::Driver::LLM::Error, /\Allm_bad_request: a: /)
        expect(fakes["b"].asks).to eq([])
      end

      context "from an llm block" do
        let(:client) { router_of(fake, max_retries: 0) }

        it "fails the step with the provider's own failure, since no provider is left" do
          fake.reply("llm-counterexamples", inserts("INSERT 0"))
              .error("llm-counterexamples", status: 429, message: "slow down")
          outcomes.push(clean)

          expect { run }.to raise_error(Quaack::Driver::LLM::Error, /\Allm_rate_limited: .*slow down/)
          expect(fake.asks.size).to eq(2)
        end
      end

      describe "the trust boundary" do
        let(:payload) do
          { "original" => "SELECT sentinel_payload_original", "candidate" => { "sql" => "sentinel_payload_candidate" },
            "untested_atoms" => ["sentinel_payload_atom"] }
        end
        let(:fakes) { { "sentinel-name-a" => fake, "sentinel-name-b" => FakeLLM.new } }

        it "sends a fresh start only the payload, the earlier inserts, and the feedback, and the enclave nothing new" do
          fake.reply("llm-counterexamples", inserts("INSERT sentinel_insert_one"))
              .error("llm-counterexamples", status: 429)
          fakes["sentinel-name-b"].reply("llm-counterexamples", inserts("INSERT sentinel_insert_two"))
                                  .reply("llm-counterexamples", inserts("INSERT sentinel_insert_three"))
          outcomes.push(clean(covered: ["sentinel_covered_atom"],
                              refused: [{ "index" => 0, "rule" => "sentinel_refusal_rule" }]), clean, clean)
          run

          messages = fakes["sentinel-name-b"].asks.first.body[:messages]
          expect(messages.size).to eq(1)
          text = messages.first[:content]
          expect(text).to eq(fresh_text([["INSERT sentinel_insert_one"],
                                         "insert 1 was refused (sentinel_refusal_rule)\n#{same}\n" \
                                         "They exercised: sentinel_covered_atom."]))
          expect(text.scan(/sentinel[\w-]*/).uniq)
            .to contain_exactly("sentinel_payload_original", "sentinel_payload_candidate", "sentinel_payload_atom",
                                "sentinel_insert_one", "sentinel_refusal_rule", "sentinel_covered_atom")
          expect(notes.join).to include("sentinel-name-a", "sentinel-name-b")
          expect(compared).to eq([["INSERT sentinel_insert_one"], ["INSERT sentinel_insert_two"],
                                  ["INSERT sentinel_insert_three"]])
        end
      end
    end
  end
end
