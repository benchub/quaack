# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "timeout"

# Tests for the checker that spec/boundary_spec.rb runs on the real gems.
# Each one plants a violation (a sentinel) and checks the checker catches it,
# so a clean result on the real gems means something.
RSpec.describe Boundary do
  let(:gem_dir) { "/fake/enclave" }
  let(:file) { "/fake/enclave/lib/quaack/enclave/step.rb" }
  let(:forbidden) { ["quaack/driver", "anthropic", "openai"] }

  def scan(source, forbidden: self.forbidden, names_only: false)
    described_class.scan_source(source, file: file, gem_dir: gem_dir, forbidden: forbidden, names_only: names_only)
  end

  # One line can break more than one rule, so compare the lines flagged.
  def flagged_lines(source, **) = scan(source, **).map(&:line).uniq

  describe ".scan_source" do
    it "flags a require of a forbidden library, with its line" do
      violations = scan(%(# comment\nrequire "quaack/driver"\n))

      expect(violations.map(&:line)).to eq([2])
      expect(violations.first.message).to include("quaack/driver")
    end

    # The runtime check never sees this, since the method never runs there.
    it "flags a forbidden require inside a method body, with its line" do
      source = %(module Quaack\n  def self.summarize\n    require "openai"\n  end\nend\n)

      expect(flagged_lines(source)).to eq([3])
    end

    it "flags a forbidden require inside a block or as another call's argument" do
      source = %(CLIENT = Once.new { require "openai" }\nlog(require("quaack/driver"))\n)

      expect(flagged_lines(source)).to eq([1, 2])
    end

    it "flags a require or require_relative of a path it can't read, even inside a method body" do
      source = <<~RUBY
        def self.summarize
          require File.expand_path("../../../../driver/lib/quaack/driver", __dir__)
        end
        require_relative name
        require "quaack/\#{side}"
      RUBY

      violations = scan(source)

      expect(violations.map(&:line)).to eq([2, 4, 5])
      expect(violations.first.message).to include("can't read")
    end

    it "flags a require of a file inside a forbidden library" do
      expect(scan(%(require "quaack/driver/cli"))).not_to be_empty
    end

    it "flags a forbidden require written with a .rb suffix" do
      expect(scan(%(require "quaack/driver.rb"))).not_to be_empty
    end

    it "flags a forbidden require hidden behind . or .. segments or doubled slashes" do
      source = %(require "quaack/../quaack/driver"\nrequire "quaack/./driver"\nrequire "quaack//driver"\n)

      expect(flagged_lines(source)).to eq([1, 2, 3])
    end

    it "flags a forbidden require written in a different case, which loads on a case-insensitive disk" do
      expect(flagged_lines(%(require "Quaack/Driver"))).to eq([1])
    end

    it "flags each forbidden LLM SDK" do
      expect(flagged_lines(%(require "anthropic"\nrequire "openai"\n))).to eq([1, 2])
    end

    it "allows libraries that aren't forbidden, including ones that only share a prefix" do
      expect(scan(%(require "pg_query"\nrequire "quaack/protocol"\nrequire "quaack/driverless"\n))).to eq([])
    end

    it "flags a require_relative that leaves the gem" do
      expect(scan(%(require_relative "../../../../driver/lib/quaack/driver"))).not_to be_empty
    end

    it "allows a require_relative that stays inside the gem" do
      expect(scan(%(require_relative "cli"\nrequire_relative "../../quaack/enclave/version"\n))).to eq([])
    end

    it "flags a require by a path outside the gem" do
      expect(scan(%(require "/fake/driver/lib/quaack/driver"))).not_to be_empty
    end

    it "flags a path into a sibling directory whose name starts with the gem's" do
      expect(flagged_lines(%(require "/fake/enclave-evil/lib/x"\nrequire_relative "../../../../enclave-evil/x"\n)))
        .to eq([1, 2])
    end

    it "flags a require relative to the working directory, since what it loads depends on where it runs" do
      expect(flagged_lines(%(require "./step"\nload "../lib/x.rb"\n))).to eq([1, 2])
    end

    it "flags load, autoload, and Kernel.require of a forbidden library" do
      source = %(load "quaack/driver.rb"\nautoload :Driver, "quaack/driver"\nKernel.require "quaack/driver"\n)

      expect(flagged_lines(source)).to eq([1, 2, 3])
    end

    it "treats require, require_relative, load, and autoload as requires whatever the receiver" do
      source = <<~RUBY
        ::Kernel.require "quaack/driver"
        self.require "quaack/driver"
        Quaack.autoload(:Driver, "quaack/driver")
        thing.require_relative "../../../../driver/x"
      RUBY

      expect(flagged_lines(source)).to eq([1, 2, 3, 4])
    end

    it "ignores other methods, including ones whose names contain require or load" do
      expect(scan(%(JSON.parse(text)\nrequired_keys(x)\nloader.call(y)\nObject.autoload(:X, "pg_query")\n))).to eq([])
    end

    it "flags Bundler.require, which would load every gem in the shared bundle" do
      source = %(require "bundler"\nBundler.require\nBundler.load\nKernel.require "pg_query"\nconfig.require\n)

      expect(flagged_lines(source)).to eq([2])
    end

    it "flags a file that doesn't parse, since it can't be checked" do
      expect(scan("require \"pg_query\"\ndef broken(\n")).not_to be_empty
    end
  end

  # Ordinary code the checker once flagged. The runtime check sees anything
  # these load when it runs, so the static check leaves them alone.
  describe ".scan_source on ordinary code" do
    it "accepts a dispatch through public_send with a built name" do
      expect(scan(%(public_send("cmd_\#{sub}", args)\n))).to eq([])
    end

    it "accepts define_method with a built name" do
      expect(scan(%(define_method("step_\#{n}") { n }\n))).to eq([])
    end

    it "accepts symbols that share a name with a require method" do
      expect(scan(%(ACTIONS = %i[save load].freeze\n))).to eq([])
    end

    it "accepts a hash whose key is require" do
      expect(scan(%(gem_options = { require: true }\n))).to eq([])
    end

    it "accepts a load whose argument isn't a string, such as JSON.load" do
      expect(scan(%(JSON.load(text)\n))).to eq([])
    end

    it "accepts send with a symbol or with a name held in a variable" do
      expect(scan(%(obj.send(:x)\nsend(pattern, node)\n))).to eq([])
    end

    it "accepts class_eval of a string that defines methods" do
      expect(scan(%(class_eval("def \#{name} = @\#{name}", __FILE__, __LINE__)\n))).to eq([])
    end

    it "accepts a change to $LOAD_PATH" do
      expect(scan(%($LOAD_PATH.unshift(File.expand_path("../lib", __dir__))\n))).to eq([])
    end
  end

  # Loading enclave code on a laptop leaks no production data, so the driver
  # gets only the forbidden-name rule.
  describe "names_only, the driver's mode" do
    let(:source) do
      <<~RUBY
        load "/etc/quaack/driver_config.rb"
        Bundler.require
        require "./local_settings"
        require_relative "../../../../tools/setup"
        require File.join(dir, "plugin")
      RUBY
    end

    it "accepts paths, Bundler.require, and requires it can't read, which the enclave's rules flag" do
      expect(flagged_lines(source)).to eq([1, 2, 3, 4, 5])
      expect(scan(source, names_only: true)).to eq([])
    end

    it "still flags a require of a forbidden library" do
      source = %(x = 1\nrequire "quaack/enclave/cli"\n)

      expect(flagged_lines(source, forbidden: ["quaack/enclave"], names_only: true)).to eq([2])
    end
  end

  describe "the real forbidden lists" do
    # Written out here, not read from LLM_SDK_REQUIRES, so dropping one from
    # that list fails this test.
    %w[
      anthropic openai ruby_llm langchain gemini-ai cohere ollama-ai mistral-ai
      groq omniai aws-sdk-bedrockruntime google/cloud/ai_platform
    ].each do |sdk|
      it "stop the enclave and the protocol gem from requiring #{sdk}" do
        [Boundary::ENCLAVE_FORBIDDEN_REQUIRES, Boundary::PROTOCOL_FORBIDDEN_REQUIRES].each do |list|
          expect(flagged_lines(%(require "#{sdk}"), forbidden: list)).to eq([1])
        end
      end
    end

    it "stop the enclave from requiring the driver or any common LLM SDK" do
      source = %w[quaack/driver quaack/driver/cli anthropic openai ruby_llm langchain].map { |lib| %(require "#{lib}") }

      expect(flagged_lines(source.join("\n"),
                           forbidden: Boundary::ENCLAVE_FORBIDDEN_REQUIRES)).to eq([1, 2, 3, 4, 5, 6])
    end

    it "stop the protocol gem from requiring the driver, the enclave, or an LLM SDK" do
      source = %w[quaack/driver quaack/enclave anthropic openai].map { |lib| %(require "#{lib}") }

      expect(flagged_lines(source.join("\n"), forbidden: Boundary::PROTOCOL_FORBIDDEN_REQUIRES)).to eq([1, 2, 3, 4])
    end

    it "stop the driver from requiring the enclave" do
      source = %(require "quaack/enclave"\nrequire "quaack/enclave/cli"\nrequire "anthropic"\n)

      expect(flagged_lines(source, forbidden: Boundary::DRIVER_FORBIDDEN_REQUIRES)).to eq([1, 2])
    end
  end

  describe ".require_violations" do
    def write(dir, path, content)
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), content)
    end

    it "scans every Ruby file under lib/ and every executable under exe/" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/quaack/ok.rb", %(require "pg_query"\n))
        write(dir, "lib/quaack/deep/bad.rb", %(require "anthropic"\n))
        write(dir, "exe/tool", %(#!/usr/bin/env ruby\nrequire "quaack/driver"\n))
        FileUtils.mkdir_p(File.join(dir, "exe", "completions"))

        violations = described_class.require_violations(dir, forbidden: forbidden)

        expect(violations.map { |v| [File.basename(v.file), v.line] }).to contain_exactly(["bad.rb", 1], ["tool", 2])
      end
    end

    it "with names_only, flags only forbidden names, not shebangs or paths" do
      Dir.mktmpdir do |dir|
        write(dir, "exe/tool", %(#!/usr/bin/ruby -w\nload "/etc/quaack/driver_config.rb"\n))
        write(dir, "lib/quaack/bad.rb", %(require "quaack/driver"\n))

        where = lambda do |**opts|
          described_class.require_violations(dir, forbidden:, **opts).map { [File.basename(it.file), it.line] }
        end

        expect(where.call).to contain_exactly(["tool", 1], ["tool", 2], ["bad.rb", 1])
        expect(where.call(names_only: true)).to eq([["bad.rb", 1]])
      end
    end

    it "requires each executable's shebang to be exactly #!/usr/bin/env ruby" do
      Dir.mktmpdir do |dir|
        write(dir, "exe/good", "#!/usr/bin/env ruby\nputs 1\n")
        write(dir, "exe/flags", "#!/usr/bin/env ruby -rquaack/driver\nputs 1\n")
        write(dir, "exe/other_ruby", "#!/usr/bin/ruby\nputs 1\n")
        write(dir, "exe/none", "puts 1\n")

        violations = described_class.require_violations(dir, forbidden: forbidden)

        expect(violations.map { |v| [File.basename(v.file), v.line] })
          .to contain_exactly(["flags", 1], ["other_ruby", 1], ["none", 1])
      end
    end
  end

  describe ".dependency_closure" do
    def gemspec(name, runtime: [], development: [])
      Gem::Specification.new do |s|
        s.name = name
        s.version = "1.0.0"
        runtime.each { |d| s.add_dependency d }
        development.each { |d| s.add_development_dependency d }
      end
    end

    let(:specs) do
      {
        "middle" => gemspec("middle", runtime: ["anthropic"], development: ["dev-of-middle"]),
        "anthropic" => gemspec("anthropic"),
        "devtool" => gemspec("devtool"),
        "ping" => gemspec("ping", runtime: ["pong"]),
        "pong" => gemspec("pong", runtime: ["ping"])
      }
    end
    let(:lookup) { ->(name) { specs[name] } }

    it "includes direct dependencies of both kinds and transitive runtime dependencies" do
      root = gemspec("root", runtime: ["middle"], development: ["devtool"])

      closure = described_class.dependency_closure(root, lookup: lookup)

      expect(closure.names).to contain_exactly("middle", "anthropic", "devtool")
      expect(closure.unresolved).to eq([])
    end

    it "lists dependencies it can't find, so they can't slip through unchecked" do
      root = gemspec("root", runtime: ["missing"])

      closure = described_class.dependency_closure(root, lookup: lookup)

      expect(closure.names).to eq(["missing"])
      expect(closure.unresolved).to eq(["missing"])
    end

    it "finishes on a dependency cycle, listing each gem once" do
      root = gemspec("root", runtime: ["ping"])

      closure = Timeout.timeout(5) { described_class.dependency_closure(root, lookup: lookup) }

      expect(closure.names).to eq(%w[ping pong])
    end
  end
end
