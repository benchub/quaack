# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Tests for the runtime check that spec/runtime_boundary_spec.rb runs on the
# real gems. Each one builds a throwaway copy of a repo gem, plants a
# violation (a sentinel) in it, and runs the real check on the copy, so a
# clean result on the real gems means something.
RSpec.describe RuntimeBoundary do
  around do |example|
    Dir.mktmpdir("quaack-runtime-checker") do |dir|
      @dir = dir
      example.run
    end
  end

  # Copies the repo gem in `gem_dir`, such as "enclave", and returns the
  # copy's gemspec path.
  def copy_of(gem_dir)
    target = File.join(@dir, "src", gem_dir)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp_r(File.join(REPO_ROOT, gem_dir), target)
    FileUtils.rm_rf(File.join(target, "spec"))
    Dir.glob(File.join(target, "*.gemspec")).fetch(0)
  end

  def add_dependency(gemspec, name)
    edit(gemspec) { |source| source.sub(/^end\n\z/, "  spec.add_dependency #{name.inspect}\nend\n") }
  end

  # Replaces `anchor` in the copy's file `relative` with `anchor` plus `code`.
  def plant(gemspec, relative, anchor, code)
    edit(File.join(File.dirname(gemspec), relative)) do |source|
      raise "#{relative} has no #{anchor.inspect}" unless source.include?(anchor)

      source.sub(anchor, "#{anchor}#{code}")
    end
  end

  def write(gemspec, relative, code)
    path = File.join(File.dirname(gemspec), relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, code)
  end

  def edit(path) = File.write(path, yield(File.read(path)))

  # A gem that isn't named like an LLM SDK but ships one under its require
  # name, the way ruby-openai ships "openai".
  let(:fake_llm_gemspec) do
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "harmless-helper"
        spec.version = "1.0.0"
        spec.authors = ["Nobody"]
        spec.summary = "A planted stand-in for an LLM SDK."
        spec.files = ["lib/openai.rb"]
      end
    RUBY
  end

  def fake_llm_gem
    gemspec = File.join(@dir, "src", "harmless-helper", "harmless-helper.gemspec")
    write(gemspec, "harmless-helper.gemspec", fake_llm_gemspec)
    write(gemspec, "lib/openai.rb", "module OpenAI; end\n")
    gemspec
  end

  def check(side) = described_class.check(side, dir: File.join(@dir, "install"))

  def messages(report, run: nil)
    report.violations.select { |v| run.nil? || v.run == run }.map(&:message)
  end

  let(:outside) { %r{loaded \S+/lib/quaack/driver\.rb, which isn't from the standard library or an allowed gem} }
  let(:forbidden) { %r{loaded \S+/lib/quaack/driver\.rb, which this side must never load} }

  it "finds nothing wrong with an unaltered copy of the enclave" do
    report = check(described_class.enclave(gemspec_path: copy_of("enclave")))

    expect(report.violations).to eq([])
  end

  describe "a dependency the gemspec declares but the allowlist doesn't" do
    it "flags the driver with no require of it, since the every-file run loads all of its files" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "quaack-driver")
      report = check(described_class.enclave(gemspec_path: gemspec))
      driver = File.join(report.install.gem_dirs.fetch("quaack-driver"), "lib", "quaack", "driver.rb")

      expect(messages(report, run: "quaacks --version")).to eq([])
      expect(messages(report, run: "every file under lib/"))
        .to include("loaded #{driver}, which isn't from the standard library or an allowed gem",
                    "loaded #{driver}, which this side must never load")
    end

    it "flags the driver, even though the gemspec pulls it in" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "quaack-driver")
      plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require "quaack/driver"\n))

      expect(messages(check(described_class.enclave(gemspec_path: gemspec)), run: "quaacks --version"))
        .to include(outside, forbidden)
    end

    it "flags the driver as forbidden even when the allowlist admits it" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "quaack-driver")
      plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require "quaack/driver"\n))
      side = described_class.enclave(gemspec_path: gemspec,
                                     allowed_gems: [*Boundary::ENCLAVE_ALLOWED_GEMS, "quaack-driver"])

      report = check(side)

      expect(messages(report)).to include(forbidden)
      expect(messages(report)).not_to include(outside)
    end

    it "flags an LLM SDK by what it loads as, whatever its gem is called" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "harmless-helper")
      plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require "openai"\n))
      side = described_class.enclave(gemspec_path: gemspec, sources: { "harmless-helper" => fake_llm_gem },
                                     allowed_gems: [*Boundary::ENCLAVE_ALLOWED_GEMS, "harmless-helper"])

      expect(messages(check(side))).to include(%r{loaded \S+/lib/openai\.rb, which this side must never load})
    end

    # The real SDK the driver uses, not a stand-in, admitted by the
    # allowlist along with its own dependencies, so only its name can flag it.
    it "flags the anthropic gem the driver uses, even when the allowlist admits it" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "anthropic")
      plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require "anthropic"\n))
      sdk = Boundary.dependency_closure(Gem::Specification.find_by_name("anthropic")).names
      side = described_class.enclave(gemspec_path: gemspec,
                                     allowed_gems: [*Boundary::ENCLAVE_ALLOWED_GEMS, "anthropic", *sdk])
      report = check(side)
      anthropic = File.join(report.install.gem_dirs.fetch("anthropic"), "lib", "anthropic.rb")

      expect(messages(report, run: "quaacks --version"))
        .to include("loaded #{anthropic}, which this side must never load")
      expect(messages(report)).to all(end_with("which this side must never load"))
    end

    it "flags any file from the installed driver gem, even one whose name isn't forbidden" do
      driver = copy_of("driver")
      write(driver, "lib/plain_helper.rb", "module PlainHelper; end\n")
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "quaack-driver")
      plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require "plain_helper"\n))
      side = described_class.enclave(gemspec_path: gemspec, sources: { "quaack-driver" => driver },
                                     allowed_gems: [*Boundary::ENCLAVE_ALLOWED_GEMS, "quaack-driver"])

      expect(messages(check(side))).to include(%r{loaded \S+/lib/plain_helper\.rb, which this side must never load})
    end
  end

  # quaack/driver itself can't load here, since the enclave's install has no
  # anthropic gem for the driver's LLM client, so the plants that load the
  # driver from the repo checkout load a file of it that needs nothing else.
  it "flags the driver loaded from the repo checkout instead of an installed gem" do
    gemspec = copy_of("enclave")
    driver = File.join(REPO_ROOT, "driver", "lib", "quaack", "driver", "version")
    plant(gemspec, "lib/quaack/enclave.rb", %(require "pg_query"\n), %(require #{driver.inspect}\n))
    loaded = "loaded #{driver}.rb, which"

    expect(messages(check(described_class.enclave(gemspec_path: gemspec))))
      .to include("#{loaded} isn't from the standard library or an allowed gem", "#{loaded} this side must never load")
  end

  describe "code that --version never reaches" do
    # These plants load the other side from the repo checkout, not through a
    # dependency. A dependency on the other side gets flagged on its own,
    # since the every-file run loads all of its files, so it would hide
    # whether the planted file was reached.
    let(:repo_driver) { File.join(REPO_ROOT, "driver", "lib", "quaack", "driver", "version.rb") }

    it "flags a lib file nothing requires that loads the driver" do
      gemspec = copy_of("enclave")
      write(gemspec, "lib/quaack/enclave/hidden.rb", %(require #{repo_driver.inspect}\n))
      report = check(described_class.enclave(gemspec_path: gemspec))

      expect(messages(report, run: "quaacks --version")).to eq([])
      expect(messages(report, run: "every file under lib/"))
        .to include("loaded #{repo_driver}, which isn't from the standard library or an allowed gem",
                    "loaded #{repo_driver}, which this side must never load")
    end

    it "flags the usage branch loading the driver" do
      gemspec = copy_of("enclave")
      add_dependency(gemspec, "quaack-driver")
      plant(gemspec, "lib/quaack/enclave/cli.rb", "      rescue Refused => e\n", %(        require "quaack/driver"\n))
      report = check(described_class.enclave(gemspec_path: gemspec))

      expect(messages(report, run: "quaacks --version")).to eq([])
      expect(messages(report, run: "quaacks")).to include(outside, forbidden)
    end

    it "flags a lib file of the protocol gem, which ships with the enclave, that loads the driver" do
      protocol = copy_of("protocol")
      write(protocol, "lib/quaack/protocol/hidden.rb", %(require #{repo_driver.inspect}\n))
      report = check(described_class.enclave(gemspec_path: copy_of("enclave"),
                                             sources: { "quaack-protocol" => protocol }))

      expect(messages(report, run: "quaacks --version")).to eq([])
      expect(messages(report, run: "every file under lib/"))
        .to include("loaded #{repo_driver}, which isn't from the standard library or an allowed gem",
                    "loaded #{repo_driver}, which this side must never load")
    end

    it "flags a run whose loaded files weren't recorded, such as one that ends with exit!" do
      gemspec = copy_of("enclave")
      plant(gemspec, "lib/quaack/enclave/cli.rb", "      rescue Refused => e\n", "        exit!(EX_USAGE)\n")

      expect(messages(check(described_class.enclave(gemspec_path: gemspec)), run: "quaacks"))
        .to eq(["recorded no loaded files"])
    end

    it "flags a lib file that fails to load, such as one requiring a gem that isn't installed" do
      gemspec = copy_of("enclave")
      write(gemspec, "lib/quaack/enclave/hidden.rb", %(require "quaack/driver"\n))

      expect(messages(check(described_class.enclave(gemspec_path: gemspec)), run: "every file under lib/"))
        .to include(%r{exited 1, not 0; stderr was .*cannot load such file -- quaack/driver}m)
    end
  end

  describe RuntimeBoundary::Rules do
    # Rules reads only the exit status.
    let(:status) { Struct.new(:exitstatus).new(0) }

    def violations(rules, feature)
      rules.run_violations("run", IsolatedInstall::Run.new("", "", status, [feature]), 0).map(&:message)
    end

    it "doesn't count a gem dir that only shares a prefix with an allowed or forbidden one", :aggregate_failures do
      rules = described_class.new(dumper: "/x/dump_features.rb",
                                  allowed_dirs: ["/x/gems/quaacks-0.1.0", "/x/gems/quaack-driver-0.1.0-extra"],
                                  forbidden_dirs: ["/x/gems/quaack-driver-0.1.0"], forbidden_requires: [])
      outside_allowed = "/x/gems/quaacks-0.1.0-extra/lib/extra.rb"

      expect(violations(rules, outside_allowed))
        .to eq(["loaded #{outside_allowed}, which isn't from the standard library or an allowed gem"])
      expect(violations(rules, "/x/gems/quaack-driver-0.1.0-extra/lib/extra.rb")).to eq([])
    end

    # A GEM_HOME often sits under a lib/ of its own, such as
    # /usr/local/lib/ruby/gems, so only the part after the gem's lib/ counts.
    it "matches a forbidden require against the path after the last lib/" do
      gem_dir = "/usr/local/lib/ruby/gems/3.4.0/gems/harmless-helper-1.0.0"
      rules = described_class.new(dumper: "/x/dump_features.rb", allowed_dirs: [gem_dir],
                                  forbidden_dirs: [], forbidden_requires: ["openai"])

      expect(violations(rules, "#{gem_dir}/lib/openai.rb"))
        .to eq(["loaded #{gem_dir}/lib/openai.rb, which this side must never load"])
    end
  end

  describe "the driver side" do
    it "flags a dependency on the enclave, even with no require of it, since every file of it gets loaded" do
      gemspec = copy_of("driver")
      add_dependency(gemspec, "quaacks")
      report = check(described_class.driver(gemspec_path: gemspec))
      enclave = File.join(report.install.gem_dirs.fetch("quaacks"), "lib", "quaack", "enclave.rb")

      expect(messages(report, run: "quaack --version")).to eq([])
      expect(messages(report, run: "every file under lib/"))
        .to include("loaded #{enclave}, which this side must never load")
    end

    # The full enclave can't load here, since the driver has no pg_query, so
    # the plant loads a file of it that needs nothing else.
    it "flags loading the enclave from a lib file --version never reaches" do
      gemspec = copy_of("driver")
      enclave = File.join(REPO_ROOT, "enclave", "lib", "quaack", "enclave", "version.rb")
      write(gemspec, "lib/quaack/driver/hidden.rb", %(require #{enclave.inspect}\n))
      report = check(described_class.driver(gemspec_path: gemspec))

      expect(messages(report, run: "quaack --version")).to eq([])
      expect(messages(report, run: "every file under lib/"))
        .to eq(["loaded #{enclave}, which isn't from the standard library or an allowed gem"])
    end
  end
end
