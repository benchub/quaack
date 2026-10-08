# frozen_string_literal: true

require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "fake_llm"

# Real LLM::Routers for specs, over real clients whose edge is a FakeLLM.
module Routers
  # The router of an llm block: one unnamed client.
  def router_of(fake, **) = Quaack::Driver::LLM::Router.one(fake.client(burndown: Quaack::Driver::Burndown.new, **))

  # The router of an llms list with one Anthropic entry per name of fakes, a
  # Hash of name to FakeLLM, in its order, and routing as llm_routing.
  # models gives an entry's model, by name; the rest have Anthropic's
  # default.
  def router_over(fakes, routing: nil, models: {}, **)
    config = { "llms" => fakes.keys.map { { "name" => it, "provider" => "anthropic", "model" => models[it] }.compact } }
    config["llm_routing"] = routing if routing
    clients = fakes.values.map { it.client(burndown: Quaack::Driver::Burndown.new, **) }
    Quaack::Driver::LLM::Router.for(Quaack::Driver::LLM.providers(config, env: {}), clients)
  end
end
