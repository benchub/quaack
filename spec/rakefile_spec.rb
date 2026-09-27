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
  # Each spec/ folder holds one spec that passes or fails as told, and prints
  # the suite's name, process id, and working directory.
  def scratch_tree(suites, failing: nil)
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(REPO_ROOT, "Rakefile"), dir)
      suites.each do |suite|
        name = suite == "." ? "root" : suite.tr("/", "_")
        FileUtils.mkdir_p(File.join(dir, suite, "spec"))
        File.write(File.join(dir, suite, "spec", "#{name}_spec.rb"), <<~RUBY)
          RSpec.describe("#{name}") { it("runs") { puts "ran:#{name} pid:\#{Process.pid} pwd:\#{Dir.pwd}"; expect(#{suite != failing}).to eq(true) } }
        RUBY
      end
      yield dir
    end
  end

  # The suites that ran, as {name => [pid, working directory]}.
  def runs(out)
    out.scan(/^ran:(\S+) pid:(\d+) pwd:(.+)$/).to_h { |name, pid, pwd| [name, [pid, pwd]] }
  end

  # A spec in a suite can't notice that suite being left out, because then it
  # never runs. So the Rakefile derives every suite, the root included, from
  # the directory tree instead of listing them.
  describe "SPEC_SUITES" do
    it "holds the root and each top-level directory that has a spec/ folder" do
      suites = scratch_tree(%w[. foo vendor vendor/x a/b foo/nested .hidden]) do |dir|
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
      expect(runs(out).keys).to contain_exactly("protocol", "enclave", "driver", "root")
    end

    it "runs each suite in its own process, from its own directory" do
      suites = spec_suites
      scratch_tree(suites) do |dir|
        out, status = rake("spec", chdir: dir)
        expect(status).to be_success, out

        pwds = runs(out).transform_values { |_, pwd| File.realpath(pwd) }
        expected = suites.to_h { |s| [s == "." ? "root" : s, File.realpath(File.join(dir, s))] }
        expect(pwds).to eq(expected)
        expect(runs(out).values.map(&:first).uniq.size).to eq(suites.size)
      end
    end

    it "runs a new top-level suite without being told about it" do
      out, status = run_suites(%w[. foo])

      expect(status).to be_success, out
      expect(runs(out).keys).to contain_exactly("root", "foo")
    end

    it "fails when a suite runs no examples" do
      out, status = scratch_tree(%w[. foo]) do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty", "spec"))
        rake("spec", chdir: dir)
      end

      expect(status).not_to be_success, out
      expect(runs(out).keys).to contain_exactly("root", "foo")
      expect(out).to include("Spec suites failed: empty/spec")
    end

    it "fails when a gem's suite fails" do
      out, status = run_suites(failing: "enclave")

      expect(status).not_to be_success, out
      expect(out).to include("Spec suites failed: enclave/spec")
    end

    it "fails when the cross-gem suite fails, after running every suite" do
      out, status = run_suites(failing: ".")

      expect(status).not_to be_success, out
      expect(runs(out).keys).to contain_exactly("protocol", "enclave", "driver", "root")
      expect(out).to include("Spec suites failed: ./spec")
    end

    # The specs above live in the root suite, so they can't catch the root
    # suite being left out. The spec task checks that itself. This swaps
    # SPEC_SUITES for a list without the root, as any mistake in deriving it
    # would, and runs the real task.
    def run_without_root(suites)
      scratch_tree(suites) do |dir|
        code = 'require "rake"; load "Rakefile"; Object.send(:remove_const, :SPEC_SUITES); ' \
               "SPEC_SUITES = %w[foo].freeze; Rake::Task[:spec].invoke"
        Open3.capture2e(RbConfig.ruby, "-e", code, chdir: dir)
      end
    end

    it "fails when the root has a spec/ folder that didn't run" do
      out, status = run_without_root(%w[. foo])

      expect(status).not_to be_success, out
      expect(runs(out).keys).to contain_exactly("foo")
      expect(out).to include("The root spec/ suite didn't run")
    end

    # Runs the real task after running `patch`, Ruby code that can wrap the
    # task's sh or Gem.ruby.
    def run_with(suites, patch)
      scratch_tree(suites) do |dir|
        code = %(require "rake"; load "Rakefile"; #{patch}; Rake::Task[:spec].invoke)
        Open3.capture2e(RbConfig.ruby, "-e", code, chdir: dir)
      end
    end

    it "fails when SPEC_SUITES holds the root but the loop never runs it" do
      out, status = run_with(%w[. foo], <<~RUBY)
        module SkipRoot
          def sh(*cmd, chdir:, **, &)
            super unless File.realpath(chdir) == File.realpath(Dir.pwd)
          end
        end
        extend SkipRoot
      RUBY

      expect(status).not_to be_success, out
      expect(runs(out).keys).to contain_exactly("foo")
      expect(out).to include("The root spec/ suite didn't run")
    end

    it "fails, and says why, when a suite can't start" do
      out, status = run_with(%w[foo], 'def Gem.ruby = "/nonexistent/ruby"')

      expect(status).not_to be_success, out
      expect(out).to include("Spec suites failed: foo/spec (couldn't start)")
    end

    it "doesn't count a root suite that couldn't start as run" do
      out, status = run_with(%w[.], 'def Gem.ruby = "/nonexistent/ruby"')

      expect(status).not_to be_success, out
      expect(out).to include("The root spec/ suite didn't run")
    end

    it "gives each failed suite's exit status" do
      out, status = run_suites(%w[. foo], failing: "foo")

      expect(status).not_to be_success, out
      expect(out).to include("Spec suites failed: foo/spec (exit 1)")
    end

    it "echoes each suite's command so it can be pasted into a shell to rerun that suite" do
      scratch_tree(%w[. foo]) do |dir|
        out, status = rake("spec", chdir: dir)
        expect(status).to be_success, out
        line = out.lines.find { |l| l.start_with?("cd ") && l.include?("/foo ") }

        rerun, = Open3.capture2e("/bin/sh", "-c", line.to_s, chdir: Dir.tmpdir)
        expect(runs(rerun).keys).to eq(["foo"])
      end
    end

    # Local rake is the only check, so personal RSpec options must not be
    # able to filter specs out, such as the boundary specs.
    describe "with personal RSpec options that exclude a suite's specs" do
      let(:exclude) { %(--exclude-pattern "**/foo_spec.rb") }

      def run_foo(env = {})
        scratch_tree(%w[. foo]) do |dir|
          yield dir if block_given?
          Open3.capture2e(env, RbConfig.ruby, "-S", "rake", "spec", chdir: dir)
        end
      end

      def expect_foo_ran(out, status)
        expect(status).to be_success, out
        expect(runs(out).keys).to contain_exactly("root", "foo")
      end

      it "ignores a .rspec-local" do
        expect_foo_ran(*run_foo { |dir| File.write(File.join(dir, "foo", ".rspec-local"), exclude) })
      end

      it "ignores SPEC_OPTS" do
        expect_foo_ran(*run_foo("SPEC_OPTS" => exclude))
      end

      it "ignores ~/.rspec" do
        Dir.mktmpdir do |home|
          File.write(File.join(home, ".rspec"), exclude)

          expect_foo_ran(*run_foo("HOME" => home, "XDG_CONFIG_HOME" => nil))
        end
      end

      it "still reads the suite's own .rspec" do
        out, status = run_foo { |dir| File.write(File.join(dir, "foo", ".rspec"), exclude) }

        expect(status).not_to be_success, out
        expect(out).to include("Spec suites failed: foo/spec (exit 1)")
      end
    end

    it "passes without the root suite when the root has no spec/ folder" do
      out, status = run_without_root(%w[foo])

      expect(status).to be_success, out
      expect(runs(out).keys).to contain_exactly("foo")
    end
  end
end
