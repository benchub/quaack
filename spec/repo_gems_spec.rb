# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe RepoGems do
  def write_gemspec(dir, file, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, file), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = #{name.inspect}
        spec.version = "1.0.0"
        spec.authors = ["Nobody"]
        spec.summary = "A fixture."
      end
    RUBY
  end

  it "finds the one gemspec in a repo directory" do
    expect(described_class.gemspec("driver").name).to eq("quaack-driver")
  end

  it "refuses a directory with two gemspecs rather than picking one" do
    Dir.mktmpdir do |root|
      write_gemspec(File.join(root, "twin"), "a.gemspec", "a")
      write_gemspec(File.join(root, "twin"), "b.gemspec", "b")

      expect { described_class.gemspec_path("twin", root: root) }
        .to raise_error(RuntimeError, %r{expected one gemspec in twin/, found \[.*a\.gemspec.*b\.gemspec.*\]})
    end
  end

  it "finds a repo gem's gemspec by gem name, not directory name" do
    expect(described_class.gemspec_path_of("quaacks")).to eq(File.join(REPO_ROOT, "enclave", "quaacks.gemspec"))
    expect(described_class.gemspec_path_of("quaack-driver"))
      .to eq(File.join(REPO_ROOT, "driver", "quaack-driver.gemspec"))
  end

  it "returns nil for a gem name no repo gem has" do
    expect(described_class.gemspec_path_of("pg_query")).to be_nil
  end

  it "names the gemspec it couldn't load" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.gemspec")
      File.write(path, "raise 'broken'\n")

      expect { described_class.load(path) }.to raise_error(RuntimeError, "couldn't load the gemspec #{path}")
    end
  end
end
