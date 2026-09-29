# frozen_string_literal: true

require_relative "lib/quaack/driver/version"

Gem::Specification.new do |spec|
  spec.name = "quaack-driver"
  spec.version = Quaack::Driver::VERSION
  spec.authors = ["Ben Chobot"]
  spec.summary = "The QUAACK driver, which runs on an engineer's laptop."
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(["lib/**/*.rb", "exe/*"], base: __dir__)
  spec.bindir = "exe"
  spec.executables = ["quaack"]
  spec.require_paths = ["lib"]

  # Never add the enclave gem here. spec/boundary_spec.rb at the repo root
  # fails if it shows up, directly or transitively.
  spec.add_dependency "quaack-protocol"
  # The official Anthropic SDK, for the LLM client. Only the driver may
  # depend on it: every LLM call runs on the laptop, never in the enclave.
  spec.add_dependency "anthropic", "~> 1.73"
  # The official OpenAI SDK, for the OpenAI-compatible adapter (OpenAI, Groq,
  # Gemini's compatible endpoint, OpenRouter, Ollama). Driver only, as above.
  spec.add_dependency "openai", "~> 0.95"
  # For splitting an operator's rewrites file into statements (step 7).
  spec.add_dependency "pg_query", "~> 6.2"
end
