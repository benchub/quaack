# frozen_string_literal: true

RSpec.describe "quaacks gemspec" do
  let(:gemspec_files) { Dir.glob("*.gemspec", base: GEM_ROOT) }
  let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, gemspec_files.fetch(0))) }

  it "is the only gemspec here, and it's named for the gem" do
    expect(gemspec_files).to eq(["quaacks.gemspec"])
  end

  it "names the gem and its one executable quaacks" do
    expect(spec.name).to eq("quaacks")
    expect(spec.executables).to eq(["quaacks"])
  end

  it "ships the executable it names" do
    expect(spec.files).to include("exe/quaacks")
  end

  it "depends at runtime on pg_query and the shared protocol gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("pg_query", "quaack-protocol")
  end
end
