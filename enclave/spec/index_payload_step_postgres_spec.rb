# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks index-payload` (README 5a-5): the shape-only payload for the LLM,
# the way the jump server runs it, after a real index-search.
RSpec.describe "quaacks index-payload, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }

  def index_payload(*extra) = quaacks.run("index-payload", "--run", store.run_id, *extra)
  def error_line(rule) = %({"type":"error","step":"index-payload","rule":"#{rule}"}\n)

  def searched
    prepare
    store.write("schema_subset", schema_subset)
    index_search
  end

  # A stored result for a partial candidate, as generator two could make
  # from the unredacted step 1 plan, with the sentinel in its predicate.
  def plant(predicate:, key: [{ "name" => "created_at", "expression" => nil, "direction" => "asc",
                                "nulls" => "last", "opclass" => nil, "collation" => nil }])
    entry = stored.read("index_search_original")
    candidate = { "table" => { "schema" => "public", "name" => "orders" }, "key" => key, "include" => [],
                  "access_method" => "btree", "predicate" => predicate, "unique" => false, "sources" => ["plan"] }
    refusal = { "rule" => "hypopg_refused", "sqlstate" => "42703", "extra" => sentinels.text }
    entry["results"] << entry["results"].first.merge("candidate" => candidate, "refusal" => refusal)
    entry["dedupe"]["set_aside"] << candidate
    stored.write("index_search_original", entry)
  end

  def payload(outcome)
    lines = outcome.stdout.lines
    expect([lines.size, lines.last, outcome.stderr, outcome.status.exitstatus])
      .to eq([2, %({"type":"done"}\n), "", 0])
    JSON.parse(lines.first)
  end

  it "sends one index_payload with the query, placeholders, plan, schema, and stats from the store" do
    searched

    sent = payload(index_payload)

    expect(sent.keys).to eq(%w[type query placeholders plan schema mechanical_results stats])
    expect(sent["type"]).to eq("index_payload")
    expect(sent["query"]).to eq(stored.read("redacted_query"))
    expect(sent["plan"]).to eq(stored.read("redacted_plan")["explain"].map { it.except("Settings") })
    expect(sent["plan"].first).to include("Plan")
    expect(sent["schema"]).to eq(schema_subset)
    expect(sent["stats"]).to eq(stored.read("classification")["outbound_statistics"])
    shapes = stored.read("placeholder_shapes")
    expect(sent["placeholders"].keys).to eq(shapes.keys)
    expect(sent["placeholders"]["$1"]).to eq(
      "type" => "text", "pattern" => nil, "elements" => nil,
      "est_rows" => shapes["$1"]["rows"]["estimated_rows"], "actual_rows" => shapes["$1"]["rows"]["actual_rows"]
    )
    expect(sent["placeholders"]["$1"]["actual_rows"]).to be_positive
  end

  context "with a timestamptz range" do
    let(:query) do
      "SELECT o.note FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at >= '2026-09-01' AND o.created_at < '2026-09-02'"
    end

    it "types each placeholder as Postgres infers it for the query" do
      searched

      types = payload(index_payload)["placeholders"].transform_values { it["type"] }

      expect(types).to eq("$1" => "text", "$2" => "timestamp with time zone", "$3" => "timestamp with time zone")
    end

    it "falls back to each placeholder's 3g type class when the query didn't prepare" do
      searched
      entry = stored.read("index_search_original")
      stored.write("index_search_original", entry.merge("parameter_types" => {}))

      types = payload(index_payload)["placeholders"].transform_values { it["type"] }

      expect(types).to eq(stored.read("placeholder_shapes").transform_values { it["type"] })
      expect(types.values).to all(be_a(String))
      expect(types["$2"]).not_to eq("timestamp with time zone")
    end
  end

  it "strips pg_dump's restrict and unrestrict lines from the schema DDL" do
    prepare
    store.write("schema_subset", "tables" => [%w[public orders]],
                                 "ddl" => "\\restrict AbC123\nCREATE TABLE public.orders (id integer);\n" \
                                          "\\unrestrict AbC123\n")
    index_search

    expect(payload(index_payload)["schema"]["ddl"]).to eq("CREATE TABLE public.orders (id integer);\n")
  end

  it "sends each mechanical result as redacted DDL, with its size, refusal, and redacted plans" do
    searched

    results = payload(index_payload)["mechanical_results"]
    entry = stored.read("index_search_original")

    expect(results.keys).to eq(%w[baseline candidates set_aside])
    expect(results["baseline"]).to eq(entry["baseline"].transform_values { it.slice("total_cost", "plan") })
    expect(results["candidates"].size).to eq(entry["results"].size)
    entry["results"].zip(results["candidates"]).each do |held, sent|
      expect(sent).to eq("ddl" => Quaack::Enclave::IndexStore.candidate(held["candidate"]).to_ddl,
                         "sources" => held["candidate"]["sources"], "partial_constant_only" => false,
                         "size" => held["size"], "refusal" => nil, "plans" => held["plans"])
    end
  end

  it "masks a real literal in a stored candidate's predicate or key expression, and keeps low-cardinality values" do
    searched
    plant(predicate: "status = '#{sentinels.text}' OR status = 'held'")
    plant(predicate: nil, key: [{ "name" => nil, "expression" => "coalesce(note, '#{sentinels.text}')",
                                  "direction" => "asc", "nulls" => "last", "opclass" => nil, "collation" => nil }])

    outcome = index_payload
    sent = payload(outcome)

    # The stand-in production server's search_path names a schema with the
    # sentinel, and the step 1 plan's Settings hold it, but they don't go out.
    expect(JSON.generate(stored.read("redacted_plan"))).to include(sentinels.text)
    expect_no_leaks(sentinels, outcome)
    expect(sent["mechanical_results"]["set_aside"].last(2).map { it["ddl"] }).to eq(
      ["CREATE INDEX ON public.orders USING btree (created_at) WHERE status = ? OR status = 'held'",
       "CREATE INDEX ON public.orders USING btree (COALESCE(note, ?))"]
    )
    planted = sent["mechanical_results"]["candidates"].last(2)
    expect(planted.map { it["ddl"] }).to eq(
      ["CREATE INDEX ON public.orders USING btree (created_at) WHERE status = ? OR status = 'held'",
       "CREATE INDEX ON public.orders USING btree (COALESCE(note, ?))"]
    )
    expect(planted.map { it["partial_constant_only"] }).to eq([true, false])
    expect(planted.map { it["refusal"] }.uniq).to eq([{ "rule" => "hypopg_refused", "sqlstate" => "42703" }])
    # The check itself catches the sentinel where it is held.
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(stored.read("index_search_original")))).not_to eq([])
  end

  it "refuses an unknown search, and a run with no index search" do
    prepare
    store.write("schema_subset", schema_subset)

    expect(index_payload.stdout).to eq(error_line("index_payload_no_index_search"))
    expect(index_payload("--search", "rewrite_1").stdout).to eq(error_line("index_payload_unknown_search"))
  end
end
