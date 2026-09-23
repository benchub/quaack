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

  def scan(source, forbidden: self.forbidden)
    described_class.scan_source(source, file: file, gem_dir: gem_dir, forbidden: forbidden)
  end

  # One line can break more than one rule, so compare the lines flagged.
  def flagged_lines(source, **) = scan(source, **).map(&:line).uniq

  describe ".scan_source" do
    it "flags a require of a forbidden library, with its line" do
      violations = scan(%(# comment\nrequire "quaack/driver"\n))

      expect(violations.map(&:line)).to eq([2])
      expect(violations.first.message).to include("quaack/driver")
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
        YAML.load(text)
      RUBY

      expect(flagged_lines(source)).to eq([1, 2, 3, 4, 5])
    end

    it "ignores other methods, including ones whose names contain require or load" do
      expect(scan(%(JSON.parse(text)\nrequired_keys(x)\nloader.call(y)\nObject.autoload(:X, "pg_query")\n))).to eq([])
    end

    it "flags requires it can't check because the argument isn't a plain string" do
      source = %(require name\nrequire "quaack/\#{side}"\nsend(:require, "quaack/driver")\n)

      expect(flagged_lines(source)).to eq([1, 2, 3])
    end

    it "flags send, public_send, and __send__ unless the method is a harmless literal" do
      source = <<~RUBY
        send("require", "quaack/driver")
        m = :size
        obj.public_send(m)
        obj.__send__(name_for(x))
        obj.send(:instance_eval, code)
        obj.send(:size)
        obj.public_send("length")
      RUBY

      expect(flagged_lines(source)).to eq([1, 3, 4, 5])
    end

    it "flags method lookups and aliases that name a require or eval method, or a name it can't read" do
      source = <<~RUBY
        method("require")
        Kernel.instance_method(name).bind_call(self, "x")
        alias_method "r", "require"
        alias_method :reload, :refresh
        define_method(:shout) { 1 }
      RUBY

      expect(flagged_lines(source)).to eq([1, 2, 3])
    end

    it "flags the symbols :require, :require_relative, :load, and :autoload anywhere, including in alias" do
      source = <<~RUBY
        m = :require
        method(:load)
        alias r require
        list = %i[autoload require_relative]
        alias_method :r, :require
        m = :required
      RUBY

      expect(flagged_lines(source)).to eq([1, 2, 3, 4, 5])
    end

    it "flags eval of a string in every form, but not instance_eval with a block" do
      source = <<~RUBY
        eval("x")
        binding.eval("x")
        Kernel.eval "x"
        obj.instance_eval("x")
        klass.class_eval "x"
        mod.module_eval("x", __FILE__)
        RubyVM::InstructionSequence.compile(s).eval
        obj.instance_eval { x }
        klass.class_eval do
          y
        end
      RUBY

      expect(flagged_lines(source)).to eq([1, 2, 3, 4, 5, 6, 7])
    end

    it "flags any use of $LOAD_PATH, $:, or $-I" do
      source = %($LOAD_PATH.unshift(File.join(__dir__, "x"))\n$: << "y"\n$-I.push("z")\npaths = $LOAD_PATH.dup\n)

      expect(flagged_lines(source)).to eq([1, 2, 3, 4])
    end

    it "flags Bundler.require, which would load every gem in the shared bundle" do
      expect(flagged_lines(%(require "bundler"\nBundler.require\n))).to eq([2])
    end

    it "flags a file that doesn't parse, since it can't be checked" do
      expect(scan("require \"pg_query\"\ndef broken(\n")).not_to be_empty
    end
  end

  describe "the real forbidden lists" do
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

        violations = described_class.require_violations(dir, forbidden: forbidden)

        expect(violations.map { |v| [File.basename(v.file), v.line] }).to contain_exactly(["bad.rb", 1], ["tool", 2])
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
