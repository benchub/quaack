# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "spec_helper"

# Task 20261003-2: which recorded replay variants spec/pipeline_replay_spec.rb
# selects, seen from a --dry-run child: on its own, as the per-commit check
# runs it, and under the Rakefile's full task. The full-task case swaps in its
# own spec task that runs the replay spec directly, so it doesn't check that
# the real spec task passes the full-replay variable on to the child suites.
# spec/rakefile_spec.rb checks that.
RSpec.describe "the pipeline replay variants each check runs" do
  def runner = "RSpec.configure { |c| c.fail_if_no_examples = true }; RSpec::Core::Runner.invoke"

  def rspec_args(out)
    ["--options", ".rspec", "--dry-run", "--format", "json", "--out", out, "spec/pipeline_replay_spec.rb"]
  end

  def descriptions(out, status, file)
    expect(status).to be_success, out
    JSON.parse(File.read(file))["examples"].map { it["full_description"] }
  end

  def plain_run
    Dir.mktmpdir do |dir|
      file = File.join(dir, "dry.json")
      out, status = Open3.capture2e({ FullReplay::ENV_VAR => nil, "SPEC_OPTS" => nil }, RbConfig.ruby,
                                    "-rrspec/core", "-e", runner, "--", *rspec_args(file), chdir: REPO_ROOT)
      descriptions(out, status, file)
    end
  end

  # The Rakefile's full task, with RuboCop and the stamp left out, and its
  # spec task replaced by a dry run of the replay spec alone.
  def full_task_code(file)
    <<~RUBY
      require "rake"
      load "Rakefile"
      def write_full_replay_stamp(*) = nil
      Rake::Task[:rubocop].clear
      Rake::Task[:spec].clear
      Rake::Task.define_task(:spec) do
        sh({ "SPEC_OPTS" => nil }, Gem.ruby, "-rrspec/core", "-e", #{runner.inspect}, "--",
           *#{rspec_args(file).inspect}, verbose: false)
      end
      Rake::Task[:full].invoke
    RUBY
  end

  def full_run
    Dir.mktmpdir do |dir|
      file = File.join(dir, "dry.json")
      out, status = Open3.capture2e({ FullReplay::ENV_VAR => nil }, RbConfig.ruby, "-e", full_task_code(file),
                                    chdir: REPO_ROOT)
      descriptions(out, status, file)
    end
  end

  # The (query, variant) pairs the recorded replay runs.
  def pairs(descriptions)
    descriptions.filter_map { it.match(/\APipelineReplay (\S+), replaying (\S+) /)&.captures }.uniq.sort
  end

  def expected(&)
    PromptPack::QUERIES.flat_map do |query|
      PipelineReplay.variants(query.name).select(&).map { [query.name, it.to_s] }
    end.sort
  end

  it "runs the first claude run of each query plus the planted and rule runs in the per-commit check" do
    runs = plain_run

    expect(pairs(runs)).to eq(expected { it.llm == "planted" || (it.llm == "claude" && it.k == 1) })
    expect(PromptPack::QUERIES.map(&:name) - pairs(runs).select { it[1] == "claude-1" }.map(&:first)).to be_empty
    expect(runs.grep(/a query the key_in_self_join rule fires on/)).not_to be_empty
    expect(runs.grep(/the planted replies read a prose-wrapped llm-rewrites reply/)).not_to be_empty
  end

  it "runs every recorded variant under rake full" do
    runs = full_run
    all = expected { true }

    expect(pairs(runs)).to eq(all)
    expect(all.size).to be > pairs(plain_run).size
    expect(runs.grep(/a query the key_in_self_join rule fires on/)).not_to be_empty
  end
end
