# frozen_string_literal: true

RSpec.describe "quaack-driver gemspec" do
  let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, "quaack-driver.gemspec")) }

  it "depends at runtime on the shared protocol gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("quaack-protocol")
  end

  # The LLM client talks to the Anthropic API through the official SDK. Only
  # the driver may depend on it; spec/boundary_spec.rb keeps it out of the
  # enclave.
  it "depends at runtime on the official anthropic gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("anthropic")
  end
end
