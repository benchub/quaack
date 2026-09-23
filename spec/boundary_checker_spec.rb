# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Tests for the checker that spec/boundary_spec.rb runs on the real gems.
# Each one plants a violation (a sentinel) and checks the checker catches it,
# so a clean result on the real gems means something.
RSpec.describe Boundary do
  let(:gem_dir) { "/fake/enclave" }
  let(:file) { "/fake/enclave/lib/quaack/enclave/step.rb" }
  let(:forbidden) { ["quaack/driver", "anthropic", "openai"] }

  def scan(source)
    described_class.scan_source(source, file: file, gem_dir: gem_dir, forbidden: forbidden)
  end

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

    it "flags each forbidden LLM SDK" do
      expect(scan(%(require "anthropic"\nrequire "openai"\n)).map(&:line)).to eq([1, 2])
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

    it "flags a require relative to the working directory, since what it loads depends on where it runs" do
      expect(scan(%(require "./step"\nload "../lib/x.rb"\n)).map(&:line)).to eq([1, 2])
    end

    it "flags load, autoload, and Kernel.require of a forbidden library" do
      source = %(load "quaack/driver.rb"\nautoload :Driver, "quaack/driver"\nKernel.require "quaack/driver"\n)

      expect(scan(source).map(&:line)).to eq([1, 2, 3])
    end

    it "flags requires it can't check because the argument isn't a plain string" do
      source = %(require name\nrequire "quaack/\#{side}"\nsend(:require, "quaack/driver")\n)

      expect(scan(source).map(&:line)).to eq([1, 2, 3])
    end

    it "flags Bundler.require, which would load every gem in the shared bundle" do
      expect(scan(%(require "bundler"\nBundler.require\n)).map(&:line)).to eq([2])
    end

    it "ignores methods that are only named like require, such as YAML.load" do
      expect(scan(%(YAML.load(text)\nconfig.require(:thing)\n))).to eq([])
    end

    it "flags a file that doesn't parse, since it can't be checked" do
      expect(scan("require \"pg_query\"\ndef broken(\n")).not_to be_empty
    end
  end

  describe ".require_violations" do
    it "scans every Ruby file under lib/ and every executable under exe/" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "quaack", "deep"))
        FileUtils.mkdir_p(File.join(dir, "exe"))
        File.write(File.join(dir, "lib", "quaack", "ok.rb"), %(require "pg_query"\n))
        File.write(File.join(dir, "lib", "quaack", "deep", "bad.rb"), %(require "anthropic"\n))
        File.write(File.join(dir, "exe", "tool"), %(#!/usr/bin/env ruby\nrequire "quaack/driver"\n))

        violations = described_class.require_violations(dir, forbidden: forbidden)

        expect(violations.map { |v| [File.basename(v.file), v.line] }).to contain_exactly(["bad.rb", 1], ["tool", 2])
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
        "devtool" => gemspec("devtool")
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
  end
end
