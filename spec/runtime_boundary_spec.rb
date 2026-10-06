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

    # Today the entry file loads nearly every other lib file itself (the LLM
    # adapters are autoloaded), so these can't always tell a run that requires
    # every file from one that requires only the entry. spec/runtime_boundary_checker_spec.rb proves that with files
    # nothing requires.
    def lib_files(gem_name)
      lib = File.join(@report.install.gem_dirs.fetch(gem_name), "lib")
      Dir.glob("**/*.rb", base: lib).map { |file| File.join(lib, file) }
    end

    it "loads every file under the installed gem's lib/ in the every-file run" do
      files = lib_files(@spec.name)

      expect(files.size).to be > 1
      expect(@report.runs.fetch("every file under lib/").loaded_features).to include(*files)
    end

    it "loads every file under the installed protocol gem's lib/ too, since it ships with this side" do
      files = lib_files("quaack-protocol")

      expect(files.size).to be > 1
      expect(@report.runs.fetch("every file under lib/").loaded_features).to include(*files)
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
                    :enclave, "enclave", "quaacks",
                    %({"type":"version","version":"#{Quaack::Enclave::VERSION}"}\n{"type":"done"}\n)
  end

  describe "the driver side" do
    it_behaves_like "a side that loads only what it may",
                    :driver, "driver", "quaack", "quaack #{Quaack::Driver::VERSION}\n" do
      # The LLM client needs each provider's SDK, which only the driver may
      # load, and it loads one only when it builds that provider's client.
      # These show the clean result above covers them, and that starting
      # loads neither.
      it "loads each LLM SDK from its installed copy when it builds a client" do
        run = @report.runs.fetch(RuntimeBoundary::BUILD_LLM_CLIENTS_RUN)

        expect(run.stdout).to eq("anthropic openai_compatible bedrock\n"), "stderr was #{run.stderr}"
        sdks = %w[anthropic openai].map { File.join(@report.install.gem_dirs.fetch(it), "lib", "#{it}.rb") }
        expect(run.loaded_features).to include(*sdks)
      end

      it "loads no LLM SDK when it starts" do
        sdk_dirs = %w[anthropic openai].map { "#{@report.install.gem_dirs.fetch(it)}/" }
        starts = @report.runs.slice("quaack --version", "quaack")

        expect(starts.size).to eq(2)
        starts.each do |label, run|
          expect(run.loaded_features).to include(end_with("/lib/quaack/driver/llm.rb"))
          expect(run.loaded_features.select { |f| f.start_with?(*sdk_dirs) }).to eq([]), label
        end
      end
    end
  end
end
