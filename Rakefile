# frozen_string_literal: true

require "rubocop/rake_task"
require "json"
require "fileutils"
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

VERSION_FILES = {
  "protocol" => "protocol/lib/quaack/protocol/version.rb",
  "driver" => "driver/lib/quaack/driver/version.rb",
  "enclave" => "enclave/lib/quaack/enclave/version.rb"
}.freeze
FULL_REPLAY_STAMP = File.join(__dir__, "spec", "fixtures", "full_replay_versions.json")

def gem_versions
  VERSION_FILES.to_h do |name, path|
    text = File.read(File.join(__dir__, path))
    [name, text[/(?:^|\s)VERSION = "([^"]+)"/, 1]]
  end
end

def write_full_replay_stamp
  FileUtils.mkdir_p(File.dirname(FULL_REPLAY_STAMP))
  File.write(FULL_REPLAY_STAMP, "#{JSON.pretty_generate(gem_versions)}\n")
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

desc "Run RuboCop and every spec, with every recorded pipeline replay variant"
task :full do
  old = ENV.fetch("QUAACK_FULL_REPLAY", nil)
  ENV["QUAACK_FULL_REPLAY"] = "1"
  Rake::Task[:rubocop].invoke
  Rake::Task[:spec].invoke
  write_full_replay_stamp
ensure
  old ? ENV["QUAACK_FULL_REPLAY"] = old : ENV.delete("QUAACK_FULL_REPLAY")
end

task default: %i[rubocop spec]
