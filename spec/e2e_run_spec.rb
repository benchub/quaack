# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../e2e/run"

# Task 20261008-71: e2e/run.rb runs a whole case end to end, so the harness
# can't rot unnoticed. Case 036 needs the LLM, so with the fake one it ends
# INFO with no fix, but it must get through the pipeline's LLM steps (which
# call the router's branches) to the report, and say why there's no fix.
RSpec.describe "e2e/run.rb" do
  it "runs case 036 through the pipeline to a judged report" do
    kase = E2ERun::Case.new(File.join(E2ERun::CASES, "036-distinct-join-to-exists"))
    result = E2ERun.run_case(TestPostgres.server, kase)
    expect([result.verdict, result.detail]).to match(["INFO", /\Ano fix selected \(.+\); needs the LLM\z/])
  end
end
