# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The isolated install must hide everything the parent process can see:
# gem directories, load paths, and a Gemfile RubyGems would activate. Each
# test plants a leak in the environment the child would inherit, and checks
# the child doesn't see it.
RSpec.describe IsolatedInstall do
  before(:context) do
    @dir = Dir.mktmpdir("quaack-isolated-install")
    spec = RepoGems.gemspec("enclave")
    @install = described_class.new(spec.name, closure: Boundary.dependency_closure(spec).names, dir: @dir)
    @script = File.join(@dir, "probe.rb")
  end

  after(:context) { FileUtils.rm_rf(@dir) }

  # Runs `code` in the isolated install as if the parent's environment, the
  # one Bundler.with_unbundled_env restores, also held `leak`.
  def probe(code, leak = {})
    File.write(@script, code)
    original = Bundler.original_env
    allow(Bundler).to receive(:original_env).and_return(original.merge(leak))
    run = @install.run_ruby(@script)
    expect(run.status).to be_success, "stderr was #{run.stderr}"
    run.stdout
  end

  it "searches only its own gem home, not the default gem directories" do
    expect(probe("puts Gem.path")).to eq("#{File.realpath(@install.home)}\n")
  end

  it "ignores a GEM_PATH in the parent's environment" do
    expect(probe("puts Gem.path", "GEM_PATH" => Gem.default_dir)).to eq("#{File.realpath(@install.home)}\n")
  end

  it "ignores a RUBYLIB in the parent's environment" do
    leak = File.join(@dir, "leak")
    FileUtils.mkdir_p(leak)

    expect(probe("puts $LOAD_PATH.include?(#{leak.inspect})", "RUBYLIB" => leak)).to eq("false\n")
  end

  it "ignores a RUBYGEMS_GEMDEPS in the parent's environment" do
    gemfile = File.join(@dir, "Gemfile.leak")
    File.write(gemfile, "")

    expect(probe("puts ENV.key?('RUBYGEMS_GEMDEPS')", "RUBYGEMS_GEMDEPS" => gemfile)).to eq("false\n")
  end

  # Bundler sets BUNDLER_VERSION when it re-execs into the lockfile's
  # version, before it records the original environment, so
  # with_unbundled_env alone keeps it.
  it "ignores a BUNDLER_VERSION in the parent's environment" do
    expect(probe("puts ENV.key?('BUNDLER_VERSION')", "BUNDLER_VERSION" => "4.0.15")).to eq("false\n")
  end

  it "loads a closure gem such as quaack-protocol from the installed copy, not the repo" do
    protocol = @install.gem_dirs.fetch("quaack-protocol")
    loaded = probe(%(require "quaack/protocol"; puts $LOADED_FEATURES.grep(%r{/quaack/protocol\\.rb\\z}))).split("\n")

    expect(protocol).to start_with(File.realpath(@install.home))
    expect(loaded).to eq([File.join(protocol, "lib", "quaack", "protocol.rb")])
  end
end
