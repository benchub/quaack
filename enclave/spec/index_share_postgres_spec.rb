# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/selection"

# Task 20261017-2 (DESIGN.md's index-share): each candidate is also
# measured with the indexes that made another candidate's ranking, so a good
# index the LLM proposed for one rewrite is tried with the others and with
# the original, not only with the candidate it was proposed for.
RSpec.describe "quaacks index-build's shared pairings, against a real server" do
  include_context "an index search run"

  let(:note) { "CREATE INDEX ON public.orders USING btree (note)" }
  let(:total) { "CREATE INDEX ON public.orders USING btree (total)" }

  def run(step, *extra) = quaacks.run(step, "--run", store.run_id, *extra, env: libpq_env)

  def add_rewrite(num, sql, top:, survived: true, pruned: false)
    stored.write("rewrite_#{num}", "sql" => sql, "anchored_sql" => sql)
    stored.write("rewrite_survived_#{num}", "survived" => survived)
    stored.write("rewrite_pruned_#{num}", "discarded" => pruned)
    rank("rewrite_#{num}", top)
  end

  # A search's ranking, as if its own index search had kept only top.
  def rank(search, top, combination: nil)
    stored.write("index_search_#{search}", "dedupe" => { "set_aside" => [] }, "set_aside" => [])
    stored.write("index_ranking_#{search}", "top" => top.map { { "ddl" => [it] } },
                                            "combination" => combination && { "ddl" => combination })
  end

  # The original's own search kept only an index its plan never uses.
  def searched
    prepare
    run("index-search")
    run("index-rank")
    rank("original", [total])
  end

  def valid(names)
    conn = production.connect
    conn.exec_params("SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
                     "WHERE c.relname = ANY($1::text[]) AND i.indisvalid",
                     [PG::TextEncoder::Array.new.encode(names)]).column_values(0)
  ensure
    conn&.close
  end

  def names(build, *ddls) = ddls.map { |ddl| build["indexes"].find { _2["ddl"] == ddl }.first }

  it "pairs each candidate with another's ranked index its plan uses, measures it, and ranks it if it's best" do
    searched
    # rewrite_1's own search found nothing useful; rewrite_2's found the note index.
    add_rewrite(1, "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1", top: [total])
    add_rewrite(2, "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY 1",
                top: [note])

    expect(run("index-build").stdout.lines.last).to eq(%({"type":"done"}\n))

    build = stored.read("index_build")
    note_name, = names(build, note)
    expect(build["combinations"]).to include("original:shared:1" => [note_name], "rewrite_1:shared:1" => [note_name])
    # rewrite_2 has the note index already, and neither plan uses the total index.
    expect(build["combinations"].keys.grep(/:shared:/)).to contain_exactly("original:shared:1", "rewrite_1:shared:1")
    expect(build["indexes"].size).to eq(2)
    expect(valid(build["indexes"].keys)).to eq([])

    %w[baseline index-baseline candidate-runs minimax].each { run(it) }
    runs = stored.read("candidate_runs")["candidates"]["rewrite_1"]
    expect(runs.keys).to contain_exactly("none", "rewrite_1:top:1", "rewrite_1:shared:1")
    expect(runs["rewrite_1:shared:1"]["slow"]["total_blocks"]).to be < runs["rewrite_1:top:1"]["slow"]["total_blocks"]
    expect(stored.read("index_baseline")["combinations"].keys).to include("original:shared:1")
    top = Quaack::Enclave::Selection.select(minimax: stored.read("minimax"),
                                            result_comparison: { "discarded" => [], "verdicts" => {} })["top"]
    expect(top.map { it["label"] }).to include("original:shared:1", "rewrite_1:shared:1")
    expect(top.find { it["kind"] == "original_new_indexes" }["label"]).to eq("original:shared:1")
  end

  it "takes only ranked indexes from candidates that go on to measurement, never set-aside or pruned ones" do
    searched
    add_rewrite(1, "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1", top: [total])
    add_rewrite(2, "SELECT o.note FROM public.orders o WHERE o.note = $1 AND o.status = $2", top: [note], pruned: true)
    entry = stored.read("index_search_rewrite_1")
    entry["set_aside"] = [Quaack::Enclave::IndexStore.candidate_plain(
      Quaack::Enclave::IndexCandidate.new(table: orders, key: %w[status total], sources: [:parse])
    )]
    stored.write("index_search_rewrite_1", entry)

    run("index-build")

    expect(stored.read("index_build")["combinations"].keys.grep(/:shared:/)).to eq([])
  end

  it "takes a ranked combination's indexes one at a time" do
    searched
    add_rewrite(1, "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1", top: [total])
    rank("rewrite_1", [total], combination: [total, note])

    run("index-build")

    build = stored.read("index_build")
    expect(build["combinations"].select { |key, _| key.include?(":shared:") })
      .to eq("original:shared:1" => names(build, note))
  end
end
