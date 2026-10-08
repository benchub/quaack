# frozen_string_literal: true

require "quaack/driver/llm"

# The llms list and llm_routing of ~/.quaack/driver.json, with QUAACK_LLM
# (DESIGN.md, "Several LLM providers").
RSpec.describe "Quaack::Driver::LLM.providers" do
  def providers(config, env: {}) = Quaack::Driver::LLM.providers(config, env:)

  # The ConfigError providers raises. Fails the spec if it raises nothing.
  def config_error(config, env: {})
    providers(config, env:)
    raise "expected an LLM::ConfigError, but providers succeeded"
  rescue Quaack::Driver::LLM::ConfigError => e
    e
  end

  def names(result) = result.entries.map(&:name)

  let(:groq) do
    { "name" => "groq", "provider" => "openai_compatible", "base_url" => "https://api.groq.com/openai/v1",
      "api_key_env" => "GROQ_API_KEY", "model" => "llama" }
  end
  let(:list) do
    [{ "name" => "opus", "provider" => "anthropic" },
     { "name" => "copilot-gpt", "provider" => "copilot_cli", "model" => "gpt-5.5" }, groq]
  end

  describe "without llms" do
    it "is Anthropic named anthropic with no llm block, and it names no entry in errors" do
      result = providers({ "jump_command" => "x" })

      expect([names(result), result.entries.first.settings.to_h, result.named])
        .to eq([["anthropic"], Quaack::Driver::LLM.settings(nil, env: {}).to_h, false])
      expect(providers(nil).entries.map(&:name)).to eq(["anthropic"])
    end

    it "makes the llm block a one-entry list named after its provider, with its overrides" do
      config = { "llm" => { "provider" => "copilot_cli", "model" => "m" } }
      result = providers(config, env: { "QUAACK_MODEL" => "from-env" })

      expect(names(result)).to eq(["copilot_cli"])
      expect(result.entries.first.settings.to_h)
        .to eq(Quaack::Driver::LLM.settings(config["llm"], env: { "QUAACK_MODEL" => "from-env" }).to_h)
    end

    it "names the entry after the provider QUAACK_LLM_PROVIDER switches to" do
      config = { "llm" => { "provider" => "copilot_cli" } }

      expect(names(providers(config, env: { "QUAACK_LLM_PROVIDER" => "anthropic" }))).to eq(["anthropic"])
    end

    it "routes always to the default: round_robin, any pairing, no steps" do
      routing = providers(nil).routing

      expect([routing.mode, routing.counterexample_pairing, routing.steps]).to eq(["round_robin", "any", {}])
    end
  end

  describe "the llms list" do
    it "gives every entry, in order, its name and settings, checked as the llm block's are" do
      result = providers({ "llms" => list })

      expect([names(result), result.named]).to eq([%w[opus copilot-gpt groq], true])
      expect(result.entries.map { it.settings.to_h }).to eq(
        [Quaack::Driver::LLM.settings({ "provider" => "anthropic" }, env: {}, at: "llms[0]").to_h,
         Quaack::Driver::LLM.settings(list[1].except("name"), env: {}, at: "llms[1]").to_h,
         Quaack::Driver::LLM.settings(groq.except("name"), env: {}, at: "llms[2]").to_h]
      )
    end

    it "lets a provider type appear more than once" do
      two = [{ "name" => "a", "provider" => "copilot_cli" }, { "name" => "b", "provider" => "copilot_cli" }]

      expect(names(providers({ "llms" => two }))).to eq(%w[a b])
    end

    it "takes nine entries" do
      nine = (1..9).map { { "name" => "e#{it}" } }

      expect(names(providers({ "llms" => nine })).size).to eq(9)
    end

    it "takes a name of 32 lowercase letters, digits, _, and -" do
      name = "a-b_c1#{"x" * 26}"

      expect(names(providers({ "llms" => [{ "name" => name }] }))).to eq([name])
    end

    {
      "an empty list" => [[], "llms in ~/.quaack/driver.json must be a list of one to nine objects"],
      "something that isn't a list" => [{ "name" => "SENTINEL-VALUE" },
                                        "llms in ~/.quaack/driver.json must be a list of one to nine objects"],
      "ten entries" => [(1..10).map { { "name" => "e#{it}" } },
                        "llms in ~/.quaack/driver.json must be a list of one to nine objects"],
      "an entry that isn't an object" => [[{ "name" => "a" }, "SENTINEL-VALUE"],
                                          "llms[1] in ~/.quaack/driver.json must be an object"],
      "an entry with no name" => [[{ "provider" => "anthropic" }],
                                  "llms[0].name in ~/.quaack/driver.json is required"],
      "a name with an uppercase letter" => [[{ "name" => "SENTINEL-VALUE" }],
                                            "llms[0].name in ~/.quaack/driver.json must be 1 to 32 lowercase " \
                                            "letters, digits, _, or -"],
      "an empty name" => [[{ "name" => "" }], "llms[0].name in ~/.quaack/driver.json must be 1 to 32 lowercase " \
                                              "letters, digits, _, or -"],
      "a name of 33 characters" => [[{ "name" => "s" * 33 }], "llms[0].name in ~/.quaack/driver.json must be 1 " \
                                                              "to 32 lowercase letters, digits, _, or -"],
      "a name that isn't a string" => [[{ "name" => 5 }], "llms[0].name in ~/.quaack/driver.json must be 1 to 32 " \
                                                          "lowercase letters, digits, _, or -"],
      "two entries with one name" => [[{ "name" => "a" }, { "name" => "b" }, { "name" => "a" }],
                                      "llms[2].name in ~/.quaack/driver.json is the same as llms[0].name"],
      "an entry's bad key, with its position" => [[{ "name" => "a" }, { "name" => "b", "model" => "" }],
                                                  "llms[1].model in ~/.quaack/driver.json must be a non-empty string"],
      "an entry's missing model" => [[{ "name" => "a" }, { "name" => "b" }, { "name" => "c" },
                                      { "name" => "d", "provider" => "openai_compatible" }],
                                     "llms[3].model in ~/.quaack/driver.json is required unless the provider " \
                                     "is anthropic"],
      "an entry's key that doesn't apply" => [[{ "name" => "a", "provider" => "copilot_cli",
                                                 "base_url" => "https://SENTINEL-VALUE" }],
                                              "llms[0].base_url in ~/.quaack/driver.json doesn't apply to " \
                                              "provider copilot_cli"]
    }.each do |what, (llms, message)|
      it "refuses #{what}, never quoting a value" do
        error = config_error({ "llms" => llms })

        expect(error.message).to eq(message)
        expect(error.message).not_to include("SENTINEL")
      end
    end

    it "refuses an entry's unknown key, naming its position" do
      expect(config_error({ "llms" => [{ "name" => "a" }, { "name" => "b", "api_key" => "SENTINEL-VALUE" }] }).message)
        .to start_with("llms[1].api_key in ~/.quaack/driver.json isn't a setting: use name, provider, model,")
    end

    it "refuses both llm and llms" do
      expect(config_error({ "llm" => {}, "llms" => list }).message)
        .to eq("use llm or llms in ~/.quaack/driver.json, not both")
    end

    it "refuses llm_routing without llms" do
      [{ "llm_routing" => {} }, { "llm" => {}, "llm_routing" => { "mode" => "failover" } }].each do |config|
        expect(config_error(config).message)
          .to eq("llm_routing in ~/.quaack/driver.json needs llms, since one provider has nothing to route")
      end
    end
  end

  describe "the environment" do
    %w[QUAACK_MODEL QUAACK_LLM_PROVIDER QUAACK_LLM_BASE_URL].each do |variable|
      it "refuses #{variable} with llms, saying to use QUAACK_LLM" do
        expect(config_error({ "llms" => list }, env: { variable => "anthropic" }).message)
          .to eq("#{variable} doesn't apply to llms in ~/.quaack/driver.json: use QUAACK_LLM instead")
      end

      it "takes an empty #{variable} with llms as unset" do
        expect(names(providers({ "llms" => list }, env: { variable => "" }))).to eq(%w[opus copilot-gpt groq])
      end
    end

    it "keeps only the entries QUAACK_LLM names, in its order" do
      expect(names(providers({ "llms" => list }, env: { "QUAACK_LLM" => "groq,opus" }))).to eq(%w[groq opus])
    end

    it "checks the entries QUAACK_LLM drops too" do
      bad = [*list, { "name" => "bad", "model" => "" }]

      expect(config_error({ "llms" => bad }, env: { "QUAACK_LLM" => "opus" }).message)
        .to eq("llms[3].model in ~/.quaack/driver.json must be a non-empty string")
    end

    it "takes an empty QUAACK_LLM as unset" do
      expect(names(providers({ "llms" => list }, env: { "QUAACK_LLM" => "" }))).to eq(%w[opus copilot-gpt groq])
    end

    it "picks the llm block's one entry by its name" do
      expect(names(providers({ "llm" => {} }, env: { "QUAACK_LLM" => "anthropic" }))).to eq(["anthropic"])
    end

    it "picks the llm block's one entry by the name of the provider QUAACK_LLM_PROVIDER switches to" do
      env = { "QUAACK_LLM_PROVIDER" => "copilot_cli", "QUAACK_MODEL" => "m", "QUAACK_LLM" => "copilot_cli" }

      expect(names(providers({ "llm" => {} }, env:))).to eq(["copilot_cli"])
    end

    [[{ "llm" => {} }, {}, "anthropic"],
     [nil, {}, "anthropic"],
     [{ "llm" => { "provider" => "copilot_cli" } }, {}, "copilot_cli"],
     [{ "llm" => {} }, { "QUAACK_LLM_PROVIDER" => "copilot_cli", "QUAACK_MODEL" => "m" }, "copilot_cli"]]
      .each do |config, env, name|
      %w[SENTINEL-VALUE opus anthropic,anthropic].each do |value|
        it "refuses a QUAACK_LLM of #{value.inspect} without llms, for #{config.inspect} and #{env.keys}" do
          error = config_error(config, env: { **env, "QUAACK_LLM" => value })

          expect(error.message).to eq("QUAACK_LLM must be #{name}, the one provider's name, since " \
                                      "~/.quaack/driver.json has no llms")
        end
      end
    end

    ["SENTINEL-VALUE", "opus,SENTINEL", "opus,,groq", "opus,opus", ","].each do |value|
      it "refuses a QUAACK_LLM of #{value.inspect}, naming the variable, not its value" do
        error = config_error({ "llms" => list }, env: { "QUAACK_LLM" => value })

        expect(error.message).to eq("QUAACK_LLM must be different names from llms in ~/.quaack/driver.json, " \
                                    "separated by commas")
      end
    end
  end

  describe "llm_routing" do
    def routing(routing, env: {}) = providers({ "llms" => list, "llm_routing" => routing }, env:).routing

    def routing_error(routing, env: {}) = config_error({ "llms" => list, "llm_routing" => routing }, env:).message

    it "takes each of its keys, and each step's" do
      steps = { "llm-rewrites" => { "fan_out" => true, "providers" => %w[groq opus] },
                "llm-counterexamples" => { "providers" => %w[opus copilot-gpt], "mode" => "failover" } }
      result = routing({ "mode" => "failover", "counterexample_pairing" => "require_different", "steps" => steps })

      expect([result.mode, result.counterexample_pairing, result.steps])
        .to eq(["failover", "require_different", steps])
    end

    it "defaults to round_robin and any" do
      result = routing({})

      expect([result.mode, result.counterexample_pairing, result.steps]).to eq(["round_robin", "any", {}])
    end

    it "takes fan_out on each of its three steps" do
      steps = %w[llm-rewrites llm-index-ideas rewrite-llm-index-ideas].to_h { [it, { "fan_out" => true }] }

      expect(routing({ "steps" => steps }).steps).to eq(steps)
    end

    it "gives a step's pool: its providers, else every entry, either less what QUAACK_LLM drops" do
      steps = { "llm-rewrites" => { "providers" => %w[groq copilot-gpt opus] } }
      env = { "QUAACK_LLM" => "opus,groq" }

      expect(routing({ "steps" => steps }).pool("llm-rewrites")).to eq(%w[groq copilot-gpt opus])
      expect(routing({ "steps" => steps }).pool("llm-index-ideas")).to eq(%w[opus copilot-gpt groq])
      expect(routing({ "steps" => steps }, env:).pool("llm-rewrites")).to eq(%w[groq opus])
      expect(routing({ "steps" => steps }, env:).pool("llm-index-ideas")).to eq(%w[opus groq])
    end

    it "takes require_different with two providers in llm-counterexamples' pool" do
      expect(routing({ "counterexample_pairing" => "require_different" }, env: { "QUAACK_LLM" => "opus,groq" })
               .counterexample_pairing).to eq("require_different")
    end

    {
      "llm_routing that isn't an object" => [["SENTINEL-VALUE"], "llm_routing in ~/.quaack/driver.json must be " \
                                                                 "an object"],
      "an unknown key" => [{ "providers" => ["opus"] },
                           "llm_routing.providers in ~/.quaack/driver.json isn't a setting: use mode, " \
                           "counterexample_pairing, or steps"],
      "an unknown mode" => [{ "mode" => "SENTINEL-VALUE" }, "llm_routing.mode in ~/.quaack/driver.json must be " \
                                                            "round_robin or failover"],
      "an unknown pairing" => [{ "counterexample_pairing" => "SENTINEL-VALUE" },
                               "llm_routing.counterexample_pairing in ~/.quaack/driver.json must be any, " \
                               "prefer_different, or require_different"],
      "steps that aren't an object" => [{ "steps" => ["SENTINEL-VALUE"] },
                                        "llm_routing.steps in ~/.quaack/driver.json must be an object"],
      "a step that isn't an LLM step" => [{ "steps" => { "index-test" => {} } },
                                          "llm_routing.steps.index-test in ~/.quaack/driver.json isn't an LLM " \
                                          "step: use llm-index-ideas, llm-index-refine, llm-rewrites, " \
                                          "operator-rewrites, llm-counterexamples, rewrite-llm-index-ideas, or " \
                                          "rewrite-llm-index-refine"],
      "a step that isn't an object" => [{ "steps" => { "llm-rewrites" => "SENTINEL-VALUE" } },
                                        "llm_routing.steps.llm-rewrites in ~/.quaack/driver.json must be an object"],
      "a step's unknown key" => [{ "steps" => { "llm-rewrites" => { "pairing" => "any" } } },
                                 "llm_routing.steps.llm-rewrites.pairing in ~/.quaack/driver.json isn't a " \
                                 "setting: use providers, mode, or fan_out"],
      "a step's unknown mode" => [{ "steps" => { "llm-rewrites" => { "mode" => "SENTINEL-VALUE" } } },
                                  "llm_routing.steps.llm-rewrites.mode in ~/.quaack/driver.json must be " \
                                  "round_robin or failover"],
      "a fan_out that isn't true or false" => [{ "steps" => { "llm-rewrites" => { "fan_out" => "SENTINEL" } } },
                                               "llm_routing.steps.llm-rewrites.fan_out in ~/.quaack/driver.json " \
                                               "must be true or false"],
      "fan_out on another step" => [{ "steps" => { "llm-counterexamples" => { "fan_out" => false } } },
                                    "llm_routing.steps.llm-counterexamples.fan_out in ~/.quaack/driver.json " \
                                    "applies only to llm-rewrites, llm-index-ideas, and rewrite-llm-index-ideas"],
      "providers that aren't a list" => [{ "steps" => { "llm-rewrites" => { "providers" => "opus" } } },
                                         "llm_routing.steps.llm-rewrites.providers in ~/.quaack/driver.json must " \
                                         "be a list of different names from llms"],
      "empty providers" => [{ "steps" => { "llm-rewrites" => { "providers" => [] } } },
                            "llm_routing.steps.llm-rewrites.providers in ~/.quaack/driver.json must be a list of " \
                            "different names from llms"],
      "a pinned name that isn't an entry" => [{ "steps" => { "llm-rewrites" => { "providers" => ["SENTINEL"] } } },
                                              "llm_routing.steps.llm-rewrites.providers in ~/.quaack/driver.json " \
                                              "must be a list of different names from llms"],
      "a pinned name twice" => [{ "steps" => { "llm-rewrites" => { "providers" => %w[opus opus] } } },
                                "llm_routing.steps.llm-rewrites.providers in ~/.quaack/driver.json must be a list " \
                                "of different names from llms"],
      "require_different with one provider pinned" => [
        { "counterexample_pairing" => "require_different",
          "steps" => { "llm-counterexamples" => { "providers" => ["opus"] } } },
        "llm_routing.counterexample_pairing in ~/.quaack/driver.json is require_different, but " \
        "llm-counterexamples has fewer than two providers"
      ]
    }.each do |what, (config, message)|
      it "refuses #{what}, never quoting a value" do
        error = routing_error(config)

        expect(error).to eq(message)
        expect(error).not_to include("SENTINEL")
      end
    end

    it "refuses require_different when QUAACK_LLM leaves one provider" do
      expect(routing_error({ "counterexample_pairing" => "require_different" }, env: { "QUAACK_LLM" => "groq" }))
        .to eq("llm_routing.counterexample_pairing in ~/.quaack/driver.json is require_different, but " \
               "llm-counterexamples has fewer than two providers")
    end

    it "refuses a pinned step that QUAACK_LLM leaves with no provider" do
      steps = { "llm-rewrites" => { "providers" => ["copilot-gpt"] } }

      expect(routing_error({ "steps" => steps }, env: { "QUAACK_LLM" => "opus" }))
        .to eq("QUAACK_LLM keeps none of llm_routing.steps.llm-rewrites.providers in ~/.quaack/driver.json")
    end
  end
end
