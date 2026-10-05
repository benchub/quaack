# frozen_string_literal: true

require_relative "support/index_search_run"

# DESIGN.md's index-baseline: `quaacks index-baseline` repeats the baseline runs for each of
# the original's index combinations kept in index-search, then hides every index again.
RSpec.describe "quaacks index-baseline, against a real server" do
  include_context "an index search run"

  def run(step) = quaacks.run(step, "--run", store.run_id, env: libpq_env)

  def baselined_run
    prepare
    %w[index-search index-rank index-build baseline].each { run(it) }
  end

  def original_keys = stored.read("index_build")["combinations"].keys.grep(/\Aoriginal:/)

  def visible_count
    conn = production.connect
    names = stored.read("index_build")["indexes"].keys
    conn.exec_params("SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
                     "WHERE c.relname = ANY($1::text[]) AND i.indisvalid",
                     [PG::TextEncoder::Array.new.encode(names)]).getvalue(0, 0)
  ensure
    conn&.close
  end

  it "measures the original under each of its combinations, leaves every index hidden, sends only done" do
    baselined_run
    build = stored.read("index_build")
    build["combinations"]["rewrite_1:top:1"] = build["combinations"].fetch("original:top:1")
    stored.write("index_build", build)

    outcome = run("index-baseline")

    expect(stored.read("index_baseline")["combinations"]).not_to have_key("rewrite_1:top:1")
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    result = stored.read("index_baseline")
    expect(original_keys).not_to be_empty
    expect(result["combinations"].keys).to match_array(original_keys)
    expect(result["timed_out"]).to eq([])
    expect(result["measurement_runs"]).to eq(original_keys.size * 9)
    result["combinations"].each_value do |sets|
      expect(sets.keys).to match_array(%w[slow worst_case typical])
      sets.each_value { expect(it["runs"].size).to eq(3) }
    end
    expect(result["combinations"]["original:top:1"]["slow"]["total_blocks"])
      .to be < stored.read("baseline")["sets"]["slow"]["total_blocks"]
    expect(visible_count).to eq("0")
  end

  it "records and counts combinations that time out under the baseline timeout" do
    baselined_run
    stored.write("baseline", stored.read("baseline").merge("timeout_ms" => 50))
    stored.write("anchored_query", "SELECT q.* FROM pg_sleep(0.3), (#{stored.read("anchored_query")}) q")

    outcome = run("index-baseline")

    expect(outcome.stdout).to eq(%({"type":"done"}\n))
    result = stored.read("index_baseline")
    expect(result["timed_out"]).to match_array(original_keys)
    expect(result["combinations"].values.flat_map(&:values)).to all(eq("timed_out" => true, "ran" => 1))
    expect(result["measurement_runs"]).to eq(original_keys.size * 3)
    expect(visible_count).to eq("0")
  end
end
