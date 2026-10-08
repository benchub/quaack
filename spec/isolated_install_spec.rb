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

  # Any Bundler variable, not just the ones Bundler itself sets, such as a
  # leftover BUNDLER_ORIG_* in a developer's shell. Bundler puts its own
  # BUNDLER_ORIG_PATH in this process's ENV too, so BUNDLER_QUAACK_LEFTOVER,
  # which only the parent's environment holds, shows the child's environment
  # is what gets scrubbed. with_unbundled_env already drops every BUNDLE_*
  # key before isolated_env scans ENV, so BUNDLE_SOMETHING can't fail today.
  # It's belt and braces, in case that order changes.
  it "ignores every BUNDLE* variable in the parent's environment" do
    leak = { "BUNDLER_ORIG_PATH" => "/leak/bin", "BUNDLE_SOMETHING" => "leak", "BUNDLER_QUAACK_LEFTOVER" => "leak" }

    expect(probe("puts ENV.keys.grep(/\\ABUNDLE/).sort", leak)).to eq("")
  end

  # The runtime boundary check builds an Anthropic::Client in the child,
  # whose constructor reads the anthropic config dir, so the child gets the
  # spec process's empty one, not the parent's or the default
  # ~/.config/anthropic.
  it "points the child's anthropic config dir at the specs' empty one" do
    leak = { "ANTHROPIC_CONFIG_DIR" => File.join(@dir, "real-anthropic") }

    expect(probe("puts ENV['ANTHROPIC_CONFIG_DIR']", leak)).to eq("#{NoRealCredentials::DIR}\n")
  end

  # It builds a Bedrock client there too, and the AWS SDK reads its config
  # and credentials files, then the EC2 metadata endpoint, unless told not
  # to, so the child gets the spec process's empty files and the endpoint
  # off, not the parent's or the default ~/.aws.
  it "points the child's AWS config and credentials files at the specs' empty ones" do
    names = %w[AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_EC2_METADATA_DISABLED]
    leak = names.to_h { [it, File.join(@dir, "real-aws")] }

    expect(probe("puts #{names}.map { ENV[it] }", leak))
      .to eq("#{File.join(NoRealCredentials::AWS_DIR, "config")}\n" \
             "#{File.join(NoRealCredentials::AWS_DIR, "credentials")}\ntrue\n")
  end

  it "still passes its own GEM_HOME and GEM_PATH to the child" do
    home = File.realpath(@install.home)

    expect(probe("puts File.realpath(ENV['GEM_HOME']), File.realpath(ENV['GEM_PATH'])")).to eq("#{home}\n#{home}\n")
  end

  it "loads a closure gem such as quaack-protocol from the installed copy, not the repo" do
    protocol = @install.gem_dirs.fetch("quaack-protocol")
    loaded = probe(%(require "quaack/protocol"; puts $LOADED_FEATURES.grep(%r{/quaack/protocol\\.rb\\z}))).split("\n")

    expect(protocol).to start_with(File.realpath(@install.home))
    expect(loaded).to eq([File.join(protocol, "lib", "quaack", "protocol.rb")])
  end
end
