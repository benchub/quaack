# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "spec_helper"
require_relative "../e2e/run"

# Task 20261008-71: e2e/run.rb runs a whole case end to end, so the harness
# can't rot unnoticed. Case 036 needs the LLM, so with the fake one it ends
# INFO with no fix, but it must get through the pipeline's LLM steps (which
# call the router's branches) to the report, and say why there's no fix.
# Task 20261008-73: the pipeline gets the case's HOME, as the CLI's does, so
# each LLM step writes the run's provenance record there.
RSpec.describe "e2e/run.rb" do
  it "runs case 036 through the pipeline to a judged report, with a provenance record" do
    kase = E2ERun::Case.new(File.join(E2ERun::CASES, "036-distinct-join-to-exists"))
    before = Dir.glob(File.join(Dir.tmpdir, "quaack-e2e-036-*"))
    result = with_kept_home { E2ERun.run_case(TestPostgres.server, kase) }
    homes = Dir.glob(File.join(Dir.tmpdir, "quaack-e2e-036-*")) - before
    records = homes.flat_map { Dir.glob(File.join(it, ".quaack", "runs", "*.llm.json")) }
    expect([result.verdict, result.detail]).to eq(["INFO", "no fix selected (declined: unused 4; existing: covered 5; rewrites: not_better 1); needs the LLM"])
    expect(records.size).to eq(1)
  ensure
    homes&.each { FileUtils.rm_rf(it) }
  end

  def with_kept_home
    saved = ENV.fetch("QUAACK_E2E_KEEP", nil)
    ENV["QUAACK_E2E_KEEP"] = "1"
    yield
  ensure
    ENV["QUAACK_E2E_KEEP"] = saved
  end
end
