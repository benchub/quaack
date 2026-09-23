# frozen_string_literal: true

require_relative "lib/quaack/protocol/version"

Gem::Specification.new do |spec|
  spec.name = "quaack-protocol"
  spec.version = Quaack::Protocol::VERSION
  spec.authors = ["Ben Chobot"]
  spec.summary = "The protocol shared by the QUAACK driver and enclave script."
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("lib/**/*.rb", base: __dir__)
  spec.require_paths = ["lib"]
end
