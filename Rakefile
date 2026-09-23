# frozen_string_literal: true

require "rubocop/rake_task"

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
# root has a spec/ folder and the root suite didn't run. That catches a wrong
# glob or a loop that skips a suite. It can't stop a deliberate edit that
# also changes this check, or that runs the root suite with its specs
# filtered out.
desc "Run every gem's specs, plus the cross-gem specs in spec/"
task :spec do
  ran = []
  failed = []
  SPEC_SUITES.each do |dir|
    sh(Gem.ruby, "-rrspec/core", "-e", RSPEC, "--", "spec", chdir: File.join(__dir__, dir)) do |ok, _|
      ran << dir
      failed << File.join(dir, "spec") unless ok
    end
  end
  abort "The root spec/ suite didn't run." if Dir.exist?(File.join(__dir__, "spec")) && !ran.include?(".")
  abort "Spec suites failed: #{failed.join(", ")}" unless failed.empty?
end

task default: %i[rubocop spec]
