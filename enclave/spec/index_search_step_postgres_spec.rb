# frozen_string_literal: true

require_relative "support/index_search_run"

# `quaacks index-search` (README 5 and 5a-1 to 5a-4) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler.
RSpec.describe "quaacks index-search, against a real server" do
  include_context "an index search run"

  def error_line(rule) = %({"type":"error","step":"index-search","rule":"#{rule}"}\n)

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("index_search_original")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  def sources(candidate) = candidate.sources.map(&:to_s).sort

  # The costs a direct EXPLAIN gives for each literal set, bound in $n
  # order, with ddl as the only hypothetical index (or none).
  def direct_costs(ddl)
    conn = production.connect
    conn.exec("SET plan_cache_mode = force_custom_plan")
    conn.exec("SELECT hypopg_create_index(#{conn.escape_literal(ddl)})") if ddl
    conn.prepare("q", stored.read("anchored_query"))
    stored.read("literal_sets").except("fallbacks").transform_values { explain_cost(conn, it) }
  ensure
    conn&.close
  end

  def explain_cost(conn, map)
    values = map.keys.sort_by { Integer(it.delete_prefix("$")) }.map { conn.escape_literal(map[it]["value"]) }
    JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) EXECUTE q(#{values.join(", ")})").getvalue(0,
                                                                                           0))[0]["Plan"]["Total Cost"]
  end

  # Makes the statistics name a column the table doesn't have, so generator
  # one INCLUDEs it for SELECT o.* and HypoPG refuses those candidates.
  def add_ghost_column
    statistics = stored.read("statistics")
    statistics["tables"][0]["column_names"] << "ghost"
    stored.write("statistics", statistics)
  end

  def restored_search(entry)
    Quaack::Enclave::IndexStore.dedupe(
      entry["dedupe"], statistics: Quaack::Enclave::PlannerStatistics.load(stored).statistics,
                       low_cardinality: Quaack::Enclave::PiiClassification.load(stored).low_cardinality
    )
  end

  it "runs the mechanical search, saves it per search, and prints only DONE" do
    prepare

    outcome = index_search

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_no_leaks(sentinels, outcome)
    entry = stored.read("index_search_original")
    search = restored_search(entry)
    expect(search.proposals.map { it.sources.to_a.sort }).to include(%i[parse plan])
    expect(search.considered).to eq(search.proposals.size + search.set_aside.size + search.drops.size)
    tested = entry["results"].map { Quaack::Enclave::IndexStore.candidate(it["candidate"]) }
    expect(tested).to eq(search.proposals)
    expect(entry["results"].map { it["candidate"]["sources"] }).to eq(search.proposals.map { sources(it) })
    expect(entry["baseline"].transform_values { it["total_cost"] }).to eq(direct_costs(nil))
    used = entry["results"].find { it["plans"].values.any? { |plan| plan["used"] } }
    expect(used["size"]).to be_a(Integer).and be_positive
    expect(entry["results"].map { it["refusal"] }.uniq).to eq([nil])
    expect(entry["results"].map { it["partial_constant_only"] })
      .to eq(entry["results"].map { !it["candidate"]["predicate"].nil? })
    ddl = Quaack::Enclave::IndexStore.candidate(used["candidate"]).to_ddl
    expect(used["plans"].transform_values { it["total_cost"] }).to eq(direct_costs(ddl))
  end

  context "when a candidate leads with a low-cardinality column (e2e 055)" do
    let(:query) { "SELECT sum(o.total) FROM public.orders o WHERE o.status = 'held'" }

    # 80% of orders are held, as 80% of e2e 055's are shipped.
    def seed(conn)
      conn.exec(<<~SQL)
        CREATE TABLE public.orders (id int PRIMARY KEY, note text, status text, total int, created_at timestamptz);
        INSERT INTO public.orders
        SELECT i, repeat('n', 200), CASE WHEN i % 5 = 0 THEN 'open' ELSE 'held' END, i % 100, now()
        FROM generate_series(1, 20000) AS i;
        ANALYZE public.orders;
      SQL
    end

    it "sets aside each unused key-only B-tree candidate on a low-cardinality leading column for 12a" do
      prepare

      index_search

      entry = stored.read("index_search_original")
      unused = entry["results"].reject { |r| r["refusal"] || r["plans"].values.any? { it["used"] } }
      expected = unused.map { it["candidate"] }.select do |c|
        c["access_method"] == "btree" && c["include"].empty? && c["predicate"].nil? && !c["unique"] &&
          c["key"].first["name"] == "status"
      end
      expect(expected).not_to be_empty
      expect(entry["set_aside"]).to eq(expected)
      expect(entry["set_aside"].map { [it["key"].map { |k| k["name"] }, it["include"]] }).to eq([[["status"], []]])
    end
  end

  it "stores each plan redacted through 3g, with placeholders where the sentinel literal was" do
    prepare
    index_search

    entry = stored.read("index_search_original")
    plans = [*entry["baseline"].values, *entry["results"].flat_map { it["plans"].values }].map { it["plan"] }
    held = JSON.generate(plans)
    expect(plans).to all(be_a(Array))
    expect(held).to include("$1")
    expect(LeakCheck.findings(sentinels, stdout: held)).to eq([])
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(stored.read("plan")))).not_to eq([])
  end

  context "when a literal's type differs from the one Postgres would infer (e2e 020)" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
        "AND o.created_at::date > now()::date - 7"
    end

    it "prepares with the literal's type, and records it as the parameter's type" do
      prepare

      outcome = index_search

      expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
      expect(stored.read("index_search_original")["parameter_types"].values).to include("integer")
    end
  end

  context "when the query selects every column" do
    let(:select_list) { "o.*" }

    it "records a candidate HypoPG refuses, with its rule and SQLSTATE" do
      prepare
      add_ghost_column

      index_search

      refusals = stored.read("index_search_original")["results"].filter_map { it["refusal"] }
      expect(refusals).not_to be_empty
      expect(refusals.uniq).to eq([{ "rule" => "hypopg_refused", "sqlstate" => refusals.first["sqlstate"] }])
      expect(refusals.first["sqlstate"]).to match(/\A[0-9A-Z]{5}\z/)
    end
  end

  it "accepts --search original, and refuses any other search" do
    prepare
    expect(index_search("--search", "original").stdout).to eq(%({"type":"done"}\n))

    outcome = index_search("--search", "rewrite_1")
    expect([outcome.stdout, outcome.status.exitstatus]).to eq([error_line("index_search_unknown_search"), 70])
  end

  it "refuses a run whose racetrack isn't set up, storing nothing" do
    prepare(racetrack_setup: false)

    expect_failed(index_search, "index_search_no_racetrack_setup")
  end

  it "fails the plan gate with its rule when the racetrack plans differently, storing nothing" do
    prepare
    conn = production.connect
    conn.exec("CREATE INDEX ON public.orders (note)")
    conn.close

    expect_failed(index_search, "plan_gate_mismatch_likely_stale_statistics")
  end
end
