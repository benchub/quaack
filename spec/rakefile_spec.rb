# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# `bundle exec rake` is the one command that runs lint and every spec. These
# specs hold the Rakefile to that.
RSpec.describe "the Rakefile" do
  def rake(*, chdir:)
    Open3.capture2e(RbConfig.ruby, "-S", "rake", *, chdir: chdir)
  end

  def spec_suites(chdir: REPO_ROOT)
    out, status = Open3.capture2e(RbConfig.ruby, "-e", 'require "rake"; load "Rakefile"; puts SPEC_SUITES',
                                  chdir: chdir)
    raise out unless status.success?

    out.split("\n")
  end

  # Builds a scratch tree that holds a copy of the real Rakefile and a spec/
  # folder in each suite directory ("." is the root), then yields its path.
  # Each spec/ folder holds one spec that passes or fails as told.
  def scratch_tree(suites, failing: nil)
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(REPO_ROOT, "Rakefile"), dir)
      suites.each do |suite|
        name = suite == "." ? "root" : suite.tr("/", "_")
        FileUtils.mkdir_p(File.join(dir, suite, "spec"))
        File.write(File.join(dir, suite, "spec", "#{name}_spec.rb"), <<~RUBY)
          RSpec.describe("#{name}") { it("runs") { puts "ran:#{name}"; expect(#{suite != failing}).to eq(true) } }
        RUBY
      end
      yield dir
    end
  end

  # A spec in a suite can't notice that suite being left out, because then it
  # never runs. So the Rakefile derives every suite, the root included, from
  # the directory tree instead of listing them.
  describe "SPEC_SUITES" do
    it "holds the root and each top-level directory that has a spec/ folder" do
      suites = scratch_tree(%w[. foo vendor/x a/b foo/nested .hidden]) do |dir|
        FileUtils.mkdir_p(File.join(dir, "bar"))
        spec_suites(chdir: dir)
      end

      expect(suites).to contain_exactly(".", "foo")
    end

    it "leaves out the root when it has no spec/ folder" do
      suites = scratch_tree(%w[foo]) { |dir| spec_suites(chdir: dir) }

      expect(suites).to contain_exactly("foo")
    end

    it "finds every suite in this repo" do
      expect(spec_suites).to include(".", "enclave", "driver", "protocol")
    end
  end

  it "runs RuboCop and then the specs by default" do
    out, status = rake("-P", chdir: REPO_ROOT)

    expect(status).to be_success, out
    expect(out[/^rake default\n((?:    .*\n)*)/, 1]).to eq("    rubocop\n    spec\n")
  end

  # Runs the real Rakefile's spec task in a scratch copy of the repo layout.
  describe "the spec task" do
    def run_suites(suites = spec_suites, failing: nil)
      scratch_tree(suites, failing: failing) { |dir| rake("spec", chdir: dir) }
    end

    it "runs every suite when they all pass" do
      out, status = run_suites

      expect(status).to be_success, out
      expect(out.scan(/^ran:(\S+)$/).flatten).to contain_exactly("protocol", "enclave", "driver", "root")
    end

    it "runs a new top-level suite without being told about it" do
      out, status = run_suites(%w[. foo])

      expect(status).to be_success, out
      expect(out.scan(/^ran:(\S+)$/).flatten).to contain_exactly("root", "foo")
    end

    it "fails when a suite runs no examples" do
      out, status = scratch_tree(%w[.]) do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty", "spec"))
        rake("spec", chdir: dir)
      end

      expect(status).not_to be_success, out
      expect(out).to include("ran:root")
    end

    it "fails when a gem's suite fails" do
      out, status = run_suites(failing: "enclave")

      expect(status).not_to be_success, out
    end

    it "fails when the cross-gem suite fails" do
      out, status = run_suites(failing: ".")

      expect(status).not_to be_success, out
    end
  end
end
