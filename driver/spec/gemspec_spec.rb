# frozen_string_literal: true

RSpec.describe "quaack-driver gemspec" do
  let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, "quaack-driver.gemspec")) }

  it "depends at runtime on the shared protocol gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("quaack-protocol")
  end
end
