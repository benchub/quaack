# frozen_string_literal: true

RSpec.describe "quaack-enclave gemspec" do
  let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, "quaack-enclave.gemspec")) }

  it "depends at runtime on pg_query and the shared protocol gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("pg_query", "quaack-protocol")
  end
end
