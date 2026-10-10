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
  # Task 20261009-49: the kept homes were found by globbing the shared system
  # tmp, so another checkout's run of this spec, at the same time, took this
  # run's home for its own and deleted it mid-run (the run failed with
  # store_error at schema-dump). So the homes are kept in a directory of this
  # spec's own, and a home it didn't make is never touched.
  it "runs case 036 through the pipeline to a judged report, with a provenance record" do
    kase = E2ERun::Case.new(File.join(E2ERun::CASES, "036-distinct-join-to-exists"))
    shared_tmp = Dir.tmpdir
    own = Dir.mktmpdir("quaack-e2e-spec-")
    foreign = nil
    result = with_kept_home(own) do
      # What a second checkout's run of this spec makes while this one runs.
      foreign = Dir.mktmpdir("quaack-e2e-036-", shared_tmp)
      E2ERun.run_case(TestPostgres.server, kase)
    end
    homes = Dir.glob(File.join(own, "quaack-e2e-036-*"))
    records = homes.flat_map { Dir.glob(File.join(it, ".quaack", "runs", "*.llm.json")) }
    why = "declined: unused 4; existing: covered 5; rewrites: not_better 1"
    expect([result.verdict, result.detail]).to eq(["INFO", "no fix selected (#{why}); needs the LLM"])
    expect(homes.size).to eq(1)
    expect(records.size).to eq(1)
    expect(File.directory?(foreign)).to be(true)
  ensure
    [own, foreign].compact.each { FileUtils.rm_rf(it) }
  end

  # Task 20261009-15: case 034's original is too slow for a 5 second
  # baseline_cap_seconds, so the case ends as an end-to-end test of the cap.
  it "runs case 034 with a short baseline cap and passes on the cap's refusal and the driver's note" do
    kase = E2ERun::Case.new(File.join(E2ERun::CASES, "034-not-in-to-not-exists"))
    result = E2ERun.run_case(TestPostgres.server, kase)
    expect(result.verdict).to eq("PASS")
    expect(result.detail).to start_with("stopped at baseline with baseline_original_exceeded_cap: The original " \
                                        "query ran past QUAACK's cap on a baseline run")
    expect(result.detail).to include("baseline_cap_seconds in ~/.quaack/config.json")
    expect(result.seconds).to be < 120
  end

  # Keeps each case's home, under tmp_dir rather than the shared system tmp.
  def with_kept_home(tmp_dir)
    saved = ENV.values_at("QUAACK_E2E_KEEP", "TMPDIR")
    ENV["QUAACK_E2E_KEEP"] = "1"
    ENV["TMPDIR"] = tmp_dir
    yield
  ensure
    ENV["QUAACK_E2E_KEEP"], ENV["TMPDIR"] = saved
  end
end
