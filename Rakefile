# frozen_string_literal: true

require "rubocop/rake_task"
require "shellwords"

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
desc "Run every gem's specs, plus the cross-gem specs in spec/"
task :spec do
  ran = []
  failed = []
  SPEC_SUITES.each do |dir|
    cmd = [Gem.ruby, "-rrspec/core", "-e", RSPEC, "--", "--options", ".rspec", "spec"]
    path = File.join(__dir__, dir)
    puts "cd #{Shellwords.escape(path)} && env -u SPEC_OPTS #{Shellwords.join(cmd)}"
    sh({ "SPEC_OPTS" => nil }, *cmd, chdir: path, verbose: false) do |ok, status|
      # sh gives nil, not false, when the command couldn't start.
      ran << dir unless ok.nil?
      failed << "#{File.join(dir, "spec")} (#{ok.nil? ? "couldn't start" : "exit #{status.exitstatus}"})" unless ok
    end
  end
  abort "The root spec/ suite didn't run." if Dir.exist?(File.join(__dir__, "spec")) && !ran.include?(".")
  abort "Spec suites failed: #{failed.join(", ")}" unless failed.empty?
end

task default: %i[rubocop spec]
