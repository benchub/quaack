# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"
require_relative "../../../../spec/support/repo_gems"
require_relative "../../../../spec/support/boundary"
require_relative "../../../../spec/support/isolated_install"

module LeakCheck
  # Runs exe/quaacks the way the jump server does: the quaacks gem built and
  # installed, with only its dependencies, into a throwaway GEM_HOME, and
  # run there in its own process, outside Bundler. This is the runtime
  # boundary check's IsolatedInstall, installed once per spec process.
  #
  # Each Quaacks has its own temporary HOME, so the runs a subcommand makes
  # land under store_base, HOME/.quaack/runs, and never in the real
  # ~/.quaack. Keep one Quaacks across calls that share a run, such as
  # intake and then a step with --run, and remove it when done.
  class Quaacks
    # What a run gave back: fd 1 and fd 2 as captured, separately, the
    # Process::Status, and the files the child loaded.
    Outcome = Data.define(:stdout, :stderr, :status, :loaded_features)

    # The one install for this process, removed when the process that made
    # it exits.
    def self.install
      @install ||= begin
        dir = Dir.mktmpdir("quaack-leak-install")
        owner = Process.pid
        at_exit { FileUtils.rm_rf(dir) if Process.pid == owner }
        spec = RepoGems.gemspec("enclave")
        IsolatedInstall.new(spec.name, closure: Boundary.dependency_closure(spec).names, dir:)
      end
    end

    attr_reader :home

    def initialize
      @home = Dir.mktmpdir("quaack-leak-home")
    end

    def store_base = File.join(home, ".quaack", "runs")
    def gem_home = Quaacks.install.home

    # The IDs of the runs under store_base, sorted.
    def runs = File.directory?(store_base) ? Dir.children(store_base).sort : []

    # Runs `quaacks *argv`, with stdin on its stdin, and returns an Outcome.
    def run(*argv, stdin: "") = outcome(Quaacks.install.run("quaacks", *argv, env: env, stdin:))

    # Runs the Ruby source the same way, such as CLI.main with a test step
    # plugged in. The installed gems are on its load path, as for the exe.
    def run_ruby(source, *argv, stdin: "")
      script = File.join(Quaacks.install.dir, "script-#{SecureRandom.hex(4)}.rb")
      File.write(script, source)
      outcome(Quaacks.install.run_ruby(script, *argv, env: env, stdin:))
    ensure
      FileUtils.rm_f(script)
    end

    def remove = FileUtils.rm_rf(home)

    private

    def env = { "HOME" => home }

    def outcome(run)
      Outcome.new(stdout: run.stdout, stderr: run.stderr, status: run.status, loaded_features: run.loaded_features)
    end
  end
end
