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

  # The OpenAI-compatible adapter talks Chat Completions through the official
  # openai gem. Like anthropic, it's on LLM_SDK_REQUIRES, so the enclave
  # stays barred from it.
  it "depends at runtime on the official openai gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("openai")
  end
end
