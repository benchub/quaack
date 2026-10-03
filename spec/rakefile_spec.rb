# frozen_string_literal: true

require "fileutils"
require "json"
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
      FileUtils.mkdir_p(File.join(dir, "rakelib"))
      FileUtils.cp(File.join(REPO_ROOT, "rakelib", "full_replay.rb"), File.join(dir, "rakelib"))
      write_versions(dir)
      suites.each { |suite| write_suite_spec(dir, suite, failing:) }
      yield dir
    end
  end

  def write_suite_spec(dir, suite, failing:)
    name = suite == "." ? "root" : suite.tr("/", "_")
    FileUtils.mkdir_p(File.join(dir, suite, "spec"))
    File.write(File.join(dir, suite, "spec", "#{name}_spec.rb"), <<~RUBY)
      RSpec.describe("#{name}") { it("runs") { puts "ran:#{name} pid:\#{Process.pid} pwd:\#{Dir.pwd}"; expect(#{suite != failing}).to eq(true) } }
    RUBY
  end

  def write_versions(dir, protocol: "1.2.3", driver: "2.3.4", enclave: "3.4.5")
    {
      "protocol/lib/quaack/protocol/version.rb" => protocol,
      "driver/lib/quaack/driver/version.rb" => driver,
      "enclave/lib/quaack/enclave/version.rb" => enclave
    }.each do |path, version|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), %(VERSION = "#{version}"\n))
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

  # The spec task's suites see QUAACK_FULL_REPLAY only when `rake full` runs
  # them, so a value exported in the shell can't make plain rake skip the
  # stamp check.
  describe "the full replay switch" do
    def write_env_spec(dir)
      File.write(File.join(dir, "spec", "env_spec.rb"), <<~RUBY)
        RSpec.describe("env") { it("prints") { puts "suite full=\#{ENV.fetch("#{FullReplay::ENV_VAR}", "unset")}" } }
      RUBY
    end

    def run_rake(*tasks, env: {})
      scratch_tree(%w[.]) do |dir|
        write_env_spec(dir)
        invokes = tasks.map { "Rake::Task[:#{it}].invoke" }.join("; ")
        code = "require 'rake'; load 'Rakefile'; Rake::Task[:rubocop].clear; " \
               "Rake::Task.define_task(:rubocop); #{invokes}"
        Open3.capture2e(env, RbConfig.ruby, "-e", code, chdir: dir)
      end
    end

    it "isn't passed to the suites by plain rake, even when exported" do
      out, status = run_rake(:spec, env: { FullReplay::ENV_VAR => "1" })

      expect(status).to be_success, out
      expect(out).to include("suite full=unset")
    end

    it "is passed to the suites by rake full" do
      out, status = run_rake(:full, env: { FullReplay::ENV_VAR => nil })

      expect(status).to be_success, out
      expect(out).to include("suite full=1")
    end
  end

  describe "the full task" do
    def run_full(spec_body: %(puts "spec full=\#{ENV.fetch("#{FullReplay::ENV_VAR}", nil)}"),
                 rubocop_body: 'puts "rubocop"', before: [], versions: {})
      scratch_tree(%w[.]) do |dir|
        write_versions(dir, **versions)
        code = full_task_code(spec_body, rubocop_body, before)
        out, status = Open3.capture2e(RbConfig.ruby, "-e", code, chdir: dir)
        stamp = File.join(dir, "spec", "fixtures", "full_replay_versions.json")
        [out, status, (JSON.parse(File.read(stamp)) if File.exist?(stamp))]
      end
    end

    def full_task_code(spec_body, rubocop_body, before)
      <<~RUBY
        require "rake"
        load "Rakefile"
        Rake::Task[:rubocop].clear
        Rake::Task.define_task(:rubocop) { #{rubocop_body} }
        Rake::Task[:spec].clear
        Rake::Task.define_task(:spec) { #{spec_body} }
        #{before.map { "Rake::Task[:#{it}].invoke" }.join("\n")}
        Rake::Task[:full].invoke
      RUBY
    end

    it "runs specs with full replay enabled and writes the versions stamp" do
      out, status, stamp = run_full

      expect(status).to be_success, out
      expect(out).to include("rubocop", "spec full=1")
      expect(stamp).to eq("protocol" => "1.2.3", "driver" => "2.3.4", "enclave" => "3.4.5")
    end

    it "does not write the versions stamp when the full replay fails" do
      out, status, stamp = run_full(spec_body: 'raise "boom"')

      expect(status).not_to be_success, out
      expect(stamp).to be_nil
    end

    it "does not run the specs or write the versions stamp when RuboCop fails" do
      out, status, stamp = run_full(rubocop_body: 'raise "rubocop offenses"')

      expect(status).not_to be_success, out
      expect(out).to include("rubocop offenses")
      expect(out).not_to include("spec full=")
      expect(stamp).to be_nil
    end

    # Rake runs a task once per invocation, so after `rake spec` or `rake
    # default`, full's own run of the specs would do nothing.
    %i[spec default].each do |task|
      it "refuses, writing no stamp, when #{task} already ran in the same rake" do
        out, status, stamp = run_full(before: [task])

        expect(status).not_to be_success, out
        expect(out).to include("rake full must run the specs itself")
        expect(out.scan("spec full=").size).to eq(1)
        expect(stamp).to be_nil
      end
    end

    it "refuses to stamp a version it can't read" do
      out, status, stamp = run_full(versions: { driver: "" })

      expect(status).not_to be_success, out
      expect(out).to include("Can't read the driver version from driver/lib/quaack/driver/version.rb")
      expect(stamp).to be_nil
    end
  end
end
