# frozen_string_literal: true

require_relative "../enclave/lib/quaack/enclave/version"
require_relative "../driver/lib/quaack/driver/version"

# The runtime half of the boundary check, run on the real gems. The check
# itself lives in spec/support/runtime_boundary.rb, which says what it covers
# and what it can't catch. spec/runtime_boundary_checker_spec.rb proves it
# catches planted violations.
RSpec.describe "what each side loads at runtime" do
  shared_examples "a side that loads only what it may" do |side, gem_dir, exe, version_line|
    before(:context) do
      @dir = Dir.mktmpdir("quaack-isolated")
      @spec = RepoGems.gemspec(gem_dir)
      @report = RuntimeBoundary.check(RuntimeBoundary.public_send(side), dir: @dir)
      @version_run = @report.runs.fetch("#{exe} --version")
    end

    after(:context) { FileUtils.rm_rf(@dir) }

    it "runs its executable from the isolated install" do
      expect(@version_run.stdout).to eq(version_line), "stderr was #{@version_run.stderr}"
      expect(@version_run.status).to be_success
    end

    it "loads nothing it isn't allowed to" do
      expect(@report.violations).to eq([]), @report.violations.join("\n")
    end

    it "requires every file under the installed gem's lib/, not only what --version loads" do
      lib = File.join(@report.install.gem_dirs.fetch(@spec.name), "lib")
      loaded = @report.runs.fetch("every file under lib/").loaded_features

      expect(loaded).to include(File.join(lib, "quaack", gem_dir, "cli.rb"), File.join(lib, "quaack", "#{gem_dir}.rb"))
    end

    it "requires every file under the installed protocol gem's lib/ too, since it ships with this side" do
      lib = File.join(@report.install.gem_dirs.fetch("quaack-protocol"), "lib", "quaack")
      loaded = @report.runs.fetch("every file under lib/").loaded_features

      expect(loaded).to include(File.join(lib, "protocol.rb"), File.join(lib, "protocol", "version.rb"))
    end

    it "loads itself from the installed gem, not from the repo checkout" do
      installed = File.realpath(File.join(@report.install.home, "gems"))
      own = @version_run.loaded_features.select { |f| f.end_with?("/lib/quaack/#{gem_dir}.rb") }

      expect(own).not_to be_empty, "stderr was #{@version_run.stderr}"
      expect(own).to all(start_with("#{installed}/#{@spec.name}-#{@spec.version}/"))
    end
  end

  describe "the enclave side" do
    it_behaves_like "a side that loads only what it may",
                    :enclave, "enclave", "quaacks", "quaacks #{Quaack::Enclave::VERSION}\n"
  end

  describe "the driver side" do
    it_behaves_like "a side that loads only what it may",
                    :driver, "driver", "quaack", "quaack #{Quaack::Driver::VERSION}\n"
  end
end
