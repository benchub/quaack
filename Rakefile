# frozen_string_literal: true

require "rubocop/rake_task"

RuboCop::RakeTask.new

# Each suite runs in its own process, from its own directory, so one gem's
# specs can't pass only because another gem's specs loaded something first.
SPEC_SUITES = %w[protocol enclave driver .].freeze

desc "Run every gem's specs, plus the cross-gem specs in spec/"
task :spec do
  SPEC_SUITES.each do |dir|
    sh Gem.ruby, "-S", "rspec", chdir: File.join(__dir__, dir)
  end
end

task default: %i[rubocop spec]
