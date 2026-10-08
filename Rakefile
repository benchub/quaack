# frozen_string_literal: true

require "rubocop/rake_task"
require "json"
require "fileutils"
require "shellwords"
require "open3"
require_relative "rakelib/full_replay"

RuboCop::RakeTask.new

# Each suite runs in its own process, from its own directory, so one gem's
# specs can't pass only because another gem's specs loaded something first.
# The suites are the root and each top-level directory, other than vendor/,
# that has a spec/ folder. They're found rather than listed, so a new gem's
# suite runs without anyone having to remember to add it.
SPEC_SUITES = (Dir.glob("{,*/}spec/", base: __dir__).map { |d| File.dirname(d) } - ["vendor"]).freeze

# This is what the rspec executable runs, plus fail_if_no_examples, which has
# no command-line flag, so an empty spec/ folder can't pass silently. RSpec
# only defaults to spec/ when $0 is "rspec", so the path is passed explicitly.
RSPEC = "RSpec.configure { |c| c.fail_if_no_examples = true }; RSpec::Core::Runner.invoke"

VERSION_FILES = {
  "protocol" => "protocol/lib/quaack/protocol/version.rb",
  "driver" => "driver/lib/quaack/driver/version.rb",
  "enclave" => "enclave/lib/quaack/enclave/version.rb"
}.freeze
FULL_REPLAY_STAMP = File.join(__dir__, "spec", "fixtures", "full_replay_versions.json")

def gem_versions
  VERSION_FILES.to_h do |name, path|
    version = File.read(File.join(__dir__, path))[/(?:^|\s)VERSION = "([^"]+)"/, 1]
    abort "Can't read the #{name} version from #{path}, so rake full won't stamp it." unless version

    [name, version]
  end
end

def write_full_replay_stamp(versions)
  FileUtils.mkdir_p(File.dirname(FULL_REPLAY_STAMP))
  File.write(FULL_REPLAY_STAMP, "#{JSON.pretty_generate(versions)}\n")
end

# Every suite runs, even after one fails, so one run shows all the results.
#
# The specs that check SPEC_SUITES live in the root suite, so they can't catch
# the root suite being left out. The task checks that itself: it fails if the
# root has a spec/ folder and the root suite didn't run, or couldn't start.
# That catches a wrong glob or a loop that skips the root suite. A loop that
# skips another suite would go unnoticed, since only the root is checked. It
# can't stop a deliberate edit that also changes this check, or that runs the
# root suite with its specs filtered out.
#
# Local rake is the only check, so personal RSpec options (.rspec-local,
# ~/.rspec, and SPEC_OPTS) must not filter specs out, such as the boundary
# specs. `--options .rspec` makes RSpec read only the suite's own .rspec, and
# SPEC_OPTS is removed from the suite's environment.
#
# The suites see QUAACK_FULL_REPLAY only while `rake full` runs them. A value
# exported in the shell is removed, so it can't make plain rake skip the
# stamp check in spec/full_replay_stamp_spec.rb.
#
# The suites run at the same time, each in its own process with its own
# Postgres container, so the check takes about as long as the slowest suite.
# Each suite's output is held until it finishes, then printed whole under a
# header that names it, says how it ended, and gives its wall time, so the
# suites' output never interleaves.
desc "Run every gem's specs, plus the cross-gem specs in spec/"
task :spec do
  ran = []
  failed = []
  printing = Mutex.new
  env = { "SPEC_OPTS" => nil, FullReplay::ENV_VAR => (Rake::Task[:full].already_invoked ? "1" : nil) }
  cmd = [Gem.ruby, "-rrspec/core", "-e", RSPEC, "--", "--options", ".rspec", "spec"]
  SPEC_SUITES.map do |dir|
    path = File.join(__dir__, dir)
    suite = File.join(dir, "spec")
    Thread.new do
      run_suite(env, *cmd, chdir: path) do |out, status, seconds|
        reason = suite_failure(status)
        outcome = status&.success? ? "passed" : "failed (#{reason})"
        print_suite(printing, "#{suite}: #{outcome} in #{format("%.1f", seconds)}s",
                    "#{rerun_line(path, cmd)}#{out}") do
          ran << dir if status
          failed << "#{suite} (#{reason})" unless status&.success?
        end
      end
    # A bug in the task itself fails only its own suite. Raised out of the
    # thread, join would re-raise it before the later suites printed.
    rescue StandardError => e
      reason = "raised #{e.class}: #{e.message}"
      print_suite(printing, "#{suite}: failed (#{reason})", rerun_line(path, cmd)) { failed << "#{suite} (#{reason})" }
    end
  end.each(&:join)
  abort "The root spec/ suite didn't run." if Dir.exist?(File.join(__dir__, "spec")) && !ran.include?(".")
  abort "Spec suites failed: #{failed.join(", ")}" unless failed.empty?
end

# The shell line that reruns one suite by hand, from any directory.
def rerun_line(path, cmd)
  "cd #{Shellwords.escape(path)} && env -u SPEC_OPTS #{Shellwords.join(cmd)}\n"
end

# Holding `printing`, records a suite's result with the block, then prints
# its header and body whole, so the suites' output never interleaves.
def print_suite(printing, header, body)
  printing.synchronize do
    yield
    puts "==> #{header}"
    print body
    $stdout.flush
  end
end

# Why a suite failed. status is nil when the command couldn't start, and a
# suite killed by a signal has no exit status.
def suite_failure(status)
  if status.nil? then "couldn't start"
  elsif status.signaled? then "killed by SIG#{Signal.signame(status.termsig)}"
  else "exit #{status.exitstatus}"
  end
end

# Runs one suite's command, holding its output, and yields the output, the
# exit status (nil if the command couldn't start), and the wall time.
def run_suite(env, *cmd, chdir:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    out, status = Open3.capture2e(env, *cmd, chdir: chdir)
  rescue SystemCallError => e
    out = "#{e.message}\n"
  end
  yield out, status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

desc "Run RuboCop and every spec, with every recorded pipeline replay variant"
task :full do
  old = ENV.fetch(FullReplay::ENV_VAR, nil)
  # Rake runs a task once per invocation, so after `rake spec full` or `rake
  # default full` the invoke below would do nothing, and the stamp would be
  # written without the full replay.
  if Rake::Task[:spec].already_invoked
    abort "The specs already ran in this rake, and rake full must run the specs itself. Run `rake full` on its own."
  end

  # Read the versions first, so an unreadable one stops the run before the
  # long replay, not after it. The stamp records the versions the run tested.
  versions = gem_versions
  ENV[FullReplay::ENV_VAR] = "1"
  Rake::Task[:rubocop].invoke
  Rake::Task[:spec].invoke
  write_full_replay_stamp(versions)
ensure
  old ? ENV[FullReplay::ENV_VAR] = old : ENV.delete(FullReplay::ENV_VAR)
end

task default: %i[rubocop spec]
