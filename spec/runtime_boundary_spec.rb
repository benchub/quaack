# frozen_string_literal: true

require_relative "../enclave/lib/quaack/enclave/version"
require_relative "../driver/lib/quaack/driver/version"

# The runtime half of the boundary check. Each side's gem is built and
# installed with only its own dependency closure, then its executable runs
# outside Bundler. Everything it loads must come from Ruby's standard library
# or from a gem in that closure. It only sees what `--version` loads, and it
# trusts the gemspec's own dependency list, so the exact dependency allowlist
# in boundary_spec.rb is what stops a new dependency on the driver.
RSpec.describe "what each side loads at runtime" do
  def stdlib_dirs
    [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"]].map { |d| File.realpath(d) }
  end

  def unexpected_features(run, install)
    allowed = [*stdlib_dirs, *install.installed_gem_dirs]
    run.loaded_features.select do |feature|
      feature.include?("/") && feature != install.dumper &&
        allowed.none? { |dir| feature.start_with?("#{dir}/") }
    end
  end

  def closure_of(name)
    spec = Gem::Specification.load(File.join(REPO_ROOT, name.delete_prefix("quaack-"), "#{name}.gemspec"))
    Boundary.dependency_closure(spec).names
  end

  shared_examples "a side that loads only its own closure" do |gem_name, exe, version_line|
    before(:context) do
      @dir = Dir.mktmpdir("quaack-isolated")
      @install = IsolatedInstall.new(gem_name, closure: closure_of(gem_name), dir: @dir)
      @run = @install.run(exe, "--version")
    end

    after(:context) { FileUtils.rm_rf(@dir) }

    it "runs its executable from the isolated install" do
      expect(@run.stdout).to eq(version_line), "stderr was #{@run.stderr}"
      expect(@run.status).to be_success
    end

    it "loads nothing from outside its dependency closure and the standard library" do
      expect(@run.loaded_features).not_to be_empty, "no features recorded; stderr was #{@run.stderr}"
      expect(unexpected_features(@run, @install)).to eq([])
    end

    it "loads itself from the installed gem, not from the repo checkout" do
      installed = File.realpath(File.join(@install.home, "gems"))
      own = @run.loaded_features.select { |f| f.end_with?("/lib/quaack/#{gem_name.delete_prefix("quaack-")}.rb") }

      expect(own).not_to be_empty, "stderr was #{@run.stderr}"
      expect(own).to all(start_with("#{installed}/#{gem_name}-"))
    end
  end

  describe "quaack-enclave" do
    it_behaves_like "a side that loads only its own closure",
                    "quaack-enclave", "quaack-enclave", "quaack-enclave #{Quaack::Enclave::VERSION}\n"
  end

  describe "quaack-driver" do
    it_behaves_like "a side that loads only its own closure",
                    "quaack-driver", "quaack", "quaack #{Quaack::Driver::VERSION}\n"
  end
end
