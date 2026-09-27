# frozen_string_literal: true

RSpec.describe "quaacks gemspec" do
  let(:gemspec_files) { Dir.glob("*.gemspec", base: GEM_ROOT) }
  let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, gemspec_files.fetch(0))) or raise "couldn't load the gemspec" }

  it "is the only gemspec here, and it's named for the gem" do
    expect(gemspec_files).to eq(["quaacks.gemspec"])
  end

  it "names the gem and its one executable quaacks" do
    expect(spec.name).to eq("quaacks")
    expect(spec.executables).to eq(["quaacks"])
  end

  # Not spec.files: RubyGems adds bindir/executables to it whether or not the
  # file exists, so that check can't fail.
  it "has the executable it names on disk, marked executable" do
    path = File.join(GEM_ROOT, spec.bindir, "quaacks")

    expect(File.file?(path)).to be(true), "#{path} is missing"
    expect(File.executable?(path)).to be(true), "#{path} isn't executable"
  end

  it "depends at runtime on pg_query and the shared protocol gem" do
    expect(spec.runtime_dependencies.map(&:name)).to include("pg_query", "quaack-protocol")
  end

  # Step 2 connects to production, and later steps to the run server.
  it "depends at runtime on pg, for its database connections" do
    expect(spec.runtime_dependencies.map(&:name)).to include("pg")
  end
end
