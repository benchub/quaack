# frozen_string_literal: true

require "rubocop/rake_task"

RuboCop::RakeTask.new

# Each suite runs in its own process, from its own directory, so one gem's
# specs can't pass only because another gem's specs loaded something first.
# The suites are the root and each top-level directory that has a spec/ folder.
# They're found, not listed, so no suite can be left out by mistake. A suite
# that runs no examples fails, so an empty spec/ folder can't pass silently.
SPEC_SUITES = Dir.glob("{,*/}spec/", base: __dir__).map { |d| File.dirname(d) }.freeze

# This is what the rspec executable runs, plus fail_if_no_examples, which has
# no command-line flag. RSpec only defaults to spec/ when $0 is "rspec", so
# the path is passed explicitly.
RSPEC = "RSpec.configure { |c| c.fail_if_no_examples = true }; RSpec::Core::Runner.invoke"

desc "Run every gem's specs, plus the cross-gem specs in spec/"
task :spec do
  SPEC_SUITES.each do |dir|
    sh Gem.ruby, "-rrspec/core", "-e", RSPEC, "spec", chdir: File.join(__dir__, dir)
  end
end

task default: %i[rubocop spec]
