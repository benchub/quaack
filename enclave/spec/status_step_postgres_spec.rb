# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks status`: which step outputs a run's store holds, so `quaack run`
# can resume.
RSpec.describe "quaacks status, against a real server" do
  include_context "an index search run"

  def status = JSON.parse(quaacks.run("status", "--run", store.run_id).stdout.lines.first)

  def index_test(stdin, *extra)
    quaacks.run("index-test", "--run", store.run_id, *extra, stdin:, env: libpq_env)
  end

  it "says which step 5 outputs are in the store, with 5a-5 done only after a first-round index-test" do
    prepare
    expect(status).to eq("type" => "status", "entries" => {
                           "index_search_original" => false, "index_generated_original" => false,
                           "index_ranking_original" => false, "rewrites_generated" => false, "index_build" => false
                         })

    index_search
    index_test(JSON.generate("ddls" => []), "--round", "refinement")
    expect(status["entries"].select { _2 }.keys).to eq(["index_search_original"])

    index_test(JSON.generate("ddls" => []))
    quaacks.run("index-rank", "--run", store.run_id, env: libpq_env)
    expect(status["entries"].values).to eq([true, true, true, false, false])
  end

  it "says whether index_build is in the store" do
    prepare
    store.write("index_build", "indexes" => {}, "combinations" => {})
    expect(status["entries"]["index_build"]).to be(true)
  end
end
