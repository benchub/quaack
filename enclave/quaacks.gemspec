# frozen_string_literal: true

require_relative "lib/quaack/enclave/version"

Gem::Specification.new do |spec|
  spec.name = "quaacks"
  spec.version = Quaack::Enclave::VERSION
  spec.authors = ["Ben Chobot"]
  spec.summary = "The QUAACK enclave script, which runs on the production jump server."
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(["lib/**/*.rb", "exe/*"], base: __dir__)
  spec.bindir = "exe"
  spec.executables = ["quaacks"]
  spec.require_paths = ["lib"]

  # Never add the driver gem or an LLM SDK here. spec/boundary_spec.rb at the
  # repo root fails if either shows up, directly or transitively.
  spec.add_dependency "pg_query", "~> 6.2"
  spec.add_dependency "quaack-protocol"
end
