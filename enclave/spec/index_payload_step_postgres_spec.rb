# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/stats_payload"

# `quaacks index-payload` (DESIGN.md's llm-index-ideas): the shape-only payload for the LLM,
# the way the jump server runs it, after a real index-search.
RSpec.describe "quaacks index-payload, against a real server" do
  include_context "an index search run"

  # The query's table and its FK parent, as schema-dump stores them.
  let(:schema_subset) do
    { "tables" => [%w[public orders], %w[public customers]],
      "ddl" => "SET statement_timeout = 0;\nCREATE TABLE public.customers (id integer);\n\n" \
               "CREATE TABLE public.orders (id integer);\n" }
  end

  def index_payload(*extra) = quaacks.run("index-payload", "--run", store.run_id, *extra)
  def error_line(rule) = %({"type":"error","step":"index-payload","rule":"#{rule}"}\n)

  def searched
    prepare
    store.write("schema_subset", schema_subset)
    index_search
  end

  # A stored result for a partial candidate, as generator two could make
  # from the unredacted input plan, with the sentinel in its predicate.
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
    expect(sent["schema"]).to eq("tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);\n")
    outbound = stored.read("classification")["outbound_statistics"]
    expect(sent["stats"]).to eq(Quaack::Enclave::StatsPayload.subset(outbound, [query]))
    expect(sent["stats"]["tables"].first["columns"].map { it["name"] }).to eq(%w[note status])
    shapes = stored.read("placeholder_shapes")
    expect(sent["placeholders"].keys).to eq(shapes.keys)
    expect(sent["placeholders"]["$1"]).to eq(
      "type" => "text", "pattern" => nil, "elements" => nil,
      "est_rows" => shapes["$1"]["rows"]["estimated_rows"], "actual_rows" => shapes["$1"]["rows"]["actual_rows"]
    )
    expect(sent["placeholders"]["$1"]["actual_rows"]).to be_positive
  end

  # DESIGN.md's llm-index-ideas: stats go out only for the columns the
  # query references. The query names note and status, not total.
  it "sends no stats for a column the query doesn't reference, and keeps the referenced ones" do
    searched
    classification = stored.read("classification")
    columns = classification["outbound_statistics"]["tables"].first["columns"]
    columns.find { it["name"] == "total" }["most_common_vals"] = [sentinels.text]
    columns.find { it["name"] == "status" }["most_common_freqs"] = [0.123456789]
    stored.write("classification", classification)

    outcome = index_payload
    sent = payload(outcome)

    expect(outcome.stdout).not_to include(sentinels.text)
    expect(sent["stats"]["tables"].first["columns"]).to eq(columns.select { %w[note status].include?(it["name"]) })
    expect(outcome.stdout).to include("0.123456789")
    expect(stored.read("classification")["outbound_statistics"]["tables"].first["columns"]).to eq(columns)
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

    it "falls back to each placeholder's redact type class when the query didn't prepare" do
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

  # This run's best candidate, the used one with the lowest total cost
  # summed over the literals: the two-column index on the query's equalities.
  let(:best_ddl) { "CREATE INDEX ON public.orders USING btree (note, status)" }

  def best(results)
    results.find { Quaack::Enclave::IndexStore.candidate(it["candidate"]).to_ddl == best_ddl }
  end

  it "sends each mechanical result as redacted DDL, with its size, refusal, and costs, and only the best one's plans" do
    searched

    results = payload(index_payload)["mechanical_results"]
    entry = stored.read("index_search_original")
    best = best(entry["results"])

    expect(results.keys).to eq(%w[baseline candidates set_aside])
    expect(results["baseline"]).to eq(entry["baseline"].transform_values { it.slice("total_cost", "plan") })
    expect([results["candidates"].size, best.nil?]).to eq([entry["results"].size, false])
    expect(entry["results"].size).to be > 1
    entry["results"].zip(results["candidates"]).each do |held, sent|
      plans = held.equal?(best) ? held["plans"] : held["plans"].transform_values { it.except("plan") }
      expect(sent).to eq("ddl" => Quaack::Enclave::IndexStore.candidate(held["candidate"]).to_ddl,
                         "sources" => held["candidate"]["sources"], "partial_constant_only" => false,
                         "size" => held["size"], "refusal" => nil, "plans" => plans)
    end
    expect(results["candidates"].count { |c| c["plans"].values.any? { it.key?("plan") } }).to eq(1)
  end

  it "keeps the plans of the used candidate that costs least, not of a cheaper unused one" do
    searched
    entry = stored.read("index_search_original")
    first = entry["results"].first
    entry["results"] << first.merge(
      "plans" => first["plans"].transform_values { it.merge("used" => false, "total_cost" => 0.0) }
    )
    stored.write("index_search_original", entry)

    candidates = payload(index_payload)["mechanical_results"]["candidates"]

    expect(candidates.last["plans"].values.map(&:keys).uniq).to eq([%w[used total_cost]])
    index = entry["results"].index { it.equal?(best(entry["results"])) }
    expect(candidates[index]["plans"]).to eq(entry["results"][index]["plans"])
  end

  it "never keeps the plans of a refused candidate, even one marked used and cheaper" do
    searched
    entry = stored.read("index_search_original")
    first = entry["results"].first
    entry["results"] << first.merge(
      "refusal" => { "rule" => "hypopg_refused", "sqlstate" => "42703" },
      "plans" => first["plans"].transform_values { it.merge("used" => true, "total_cost" => 0.0) }
    )
    stored.write("index_search_original", entry)

    candidates = payload(index_payload)["mechanical_results"]["candidates"]

    expect(candidates.last["plans"].values.map(&:keys).uniq).to eq([%w[used total_cost]])
    index = entry["results"].index { it.equal?(best(entry["results"])) }
    expect(candidates[index]["plans"]).to eq(entry["results"][index]["plans"])
  end

  it "masks a real literal in a stored candidate's predicate or key expression, and keeps low-cardinality values" do
    searched
    plant(predicate: "status = '#{sentinels.text}' OR status = 'held'")
    plant(predicate: nil, key: [{ "name" => nil, "expression" => "coalesce(note, '#{sentinels.text}')",
                                  "direction" => "asc", "nulls" => "last", "opclass" => nil, "collation" => nil }])

    outcome = index_payload
    sent = payload(outcome)

    # The stand-in production server's search_path names a schema with the
    # sentinel, and the input plan's Settings hold it, but they don't go out.
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
