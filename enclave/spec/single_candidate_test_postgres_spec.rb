# frozen_string_literal: true

require "json"
require "quaack/enclave/single_candidate_test"

# 5a-4 against real HypoPG on the test harness. The table's s column is
# skewed: 90% of rows hold 0, and the rest each hold a value of their own.
# So s = 0 wants a sequential scan and s = 10 wants an index.
RSpec.describe Quaack::Enclave::SingleCandidateTest do
  let(:conn) { test_database.connection }
  let(:t) { Quaack::Enclave::TableName.new(schema: "public", name: "t") }
  let(:sentinel) { "SENTINEL-5a4-7f3c" }

  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS hypopg;
      CREATE TABLE t (a int, b int, c int, s int, flag text);
      INSERT INTO t SELECT i, i % 1000, i, CASE WHEN i % 10 = 0 THEN i ELSE 0 END,
                           CASE WHEN i % 100 = 0 THEN 'open' ELSE 'closed' END
      FROM generate_series(1, 100000) AS i;
    SQL
    conn.exec("VACUUM ANALYZE t")
  end

  def candidate(**)
    Quaack::Enclave::IndexCandidate.new(table: t, sources: [:parse], **)
  end

  def key(name, direction) = Quaack::Enclave::IndexCandidate::KeyColumn.new(name:, direction:)

  def run(query, literal_sets, candidates)
    described_class.run(conn, query:, literal_sets:, candidates:)
  end

  def index_names(explain)
    walk = ->(node) { [node["Index Name"], *(node["Plans"] || []).flat_map(&walk)] }
    walk[explain.first["Plan"]].compact
  end

  def inline_explain(query)
    JSON.parse(conn.exec("EXPLAIN (FORMAT JSON) #{query}").getvalue(0, 0))
  end

  def leftovers
    {
      hypothetical: conn.exec("SELECT count(*) FROM hypopg_list_indexes").getvalue(0, 0).to_i,
      prepared: conn.exec("SELECT count(*) FROM pg_prepared_statements").getvalue(0, 0).to_i,
      transaction: conn.transaction_status,
      plan_cache_mode: conn.exec("SHOW plan_cache_mode").getvalue(0, 0)
    }
  end

  let(:clean) { { hypothetical: 0, prepared: 0, transaction: 0, plan_cache_mode: "auto" } }

  it "marks a candidate the planner uses as used, and keeps one it ignores as unused" do
    used = candidate(key: ["a"])
    ignored = candidate(key: ["c"])
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"], typical: ["70000"] }, [used, ignored])

    expect(report.results.map(&:candidate)).to eq([used, ignored])
    expect(report.results.map(&:used?)).to eq([true, false])
    expect(report.results.map { |r| r.plans.transform_values(&:used) })
      .to eq([{ slow: true, typical: true }, { slow: false, typical: false }])
    expect(report.results.map(&:refusal)).to eq([nil, nil])
    expect(report.results.map(&:size)).to all(be_an(Integer).and(be_positive))
  end

  it "records each candidate's hypopg_relation_size" do
    small = candidate(key: ["b"], predicate: "flag = 'open'")
    large = candidate(key: %w[a c])
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [small, large])

    expected = [small, large].map do |c|
      conn.exec("SELECT hypopg_reset()")
      oid = conn.exec_params("SELECT indexrelid FROM hypopg_create_index($1)", [c.to_ddl]).getvalue(0, 0)
      conn.exec_params("SELECT hypopg_relation_size($1)", [oid]).getvalue(0, 0).to_i
    ensure
      conn.exec("SELECT hypopg_reset()")
    end
    expect(expected[0]).to be < expected[1]
    expect(report.results.map(&:size)).to eq(expected)
  end

  it "costs each literal set on its own, so a skewed column's literals differ" do
    report = run("SELECT * FROM t WHERE s = $1", { slow: ["10"], worst: ["0"] }, [candidate(key: ["s"])])
    result = report.results.first

    expect(result.plans.transform_values(&:used)).to eq(slow: true, worst: false)
    expect(result.used?).to be(true)
    expect(result.plans[:slow].total_cost).to be < result.plans[:worst].total_cost
    expect(result.plans[:slow].total_cost).to be < report.baseline.plans[:slow].total_cost
    expect(report.baseline.plans.transform_values(&:used)).to eq(slow: false, worst: false)
    expect(report.baseline.plans.values.map { |p| index_names(p.raw_plan) }).to eq([[], []])
  end

  # Postgres may switch a prepared statement to a generic plan after five
  # executions, and a generic plan wouldn't see a new hypothetical index.
  it "plans every EXPLAIN afresh, however many run" do
    ignored = Array.new(4) { |i| candidate(key: ["c"], predicate: "a = #{i}") }
    report = run("SELECT * FROM t WHERE s = $1", { worst: ["0"], slow: ["10"] }, [*ignored, candidate(key: ["s"])])

    expect(report.results.last.plans.transform_values(&:used)).to eq(worst: false, slow: true)
  end

  it "plans the literals the way EXPLAIN with them inlined does, with and without the candidate" do
    candidate = candidate(key: ["s"])
    report = run("SELECT * FROM t WHERE s = $1", { selective: ["10"], unselective: ["0"] }, [candidate])

    { selective: 10, unselective: 0 }.each do |set, value|
      baseline = inline_explain("SELECT * FROM t WHERE s = #{value}")
      expect(report.baseline.plans[set].total_cost).to eq(baseline.first["Plan"]["Total Cost"])
      expect(report.baseline.plans[set].canonical_plan)
        .to be_matches(Quaack::Enclave::CanonicalPlan.new(baseline, hypothetical_indexes: {}))

      oid = conn.exec_params("SELECT indexrelid FROM hypopg_create_index($1)", [candidate.to_ddl]).getvalue(0, 0)
      with_index = inline_explain("SELECT * FROM t WHERE s = #{value}")
      conn.exec("SELECT hypopg_reset()")
      expect(report.results.first.plans[set].total_cost).to eq(with_index.first["Plan"]["Total Cost"])
      expect(report.results.first.plans[set].canonical_plan)
        .to be_matches(Quaack::Enclave::CanonicalPlan.new(with_index,
                                                          hypothetical_indexes: { Integer(oid) => candidate.to_ddl }))
    end
  end

  # A bound NULL parameter, as the production session sends it. An inlined
  # NULL would turn into "flag IS NULL" at parse time.
  it "plans a nil literal as NULL" do
    report = run("SELECT * FROM t WHERE flag IS NOT DISTINCT FROM $1", { slow: [nil] }, [])

    expect(report.baseline.plans[:slow].raw_plan.first["Plan"]["Filter"])
      .to eq("(NOT (flag IS DISTINCT FROM NULL::text))")
  end

  it "tests a partial candidate, used only when the query implies its predicate" do
    matching = candidate(key: ["b"], predicate: "flag = 'open'")
    other = candidate(key: ["b"], predicate: "flag = 'closed'")
    report = run("SELECT * FROM t WHERE b = $1 AND flag = 'open'", { slow: ["100"] }, [matching, other])

    expect(report.results.map(&:used?)).to eq([true, false])
  end

  it "keeps each candidate out of the others' plans" do
    first = candidate(key: ["a"])
    second = candidate(key: ["c"])
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [first, second])

    expect(index_names(report.results[1].plans[:slow].raw_plan)).to eq([])
    expect(report.results[1].plans[:slow].canonical_plan).to be_matches(report.baseline.plans[:slow].canonical_plan)
    expect(report.results[0].plans[:slow].canonical_plan)
      .not_to be_matches(report.baseline.plans[:slow].canonical_plan)
  end

  it "tells apart candidates that HypoPG gives the same automatic name" do
    ascending = candidate(key: ["b"])
    descending = candidate(key: [key("b", :desc)])
    report = run("SELECT * FROM t WHERE b = $1", { slow: ["7"] }, [ascending, descending])
    plans = report.results.map { |r| r.plans[:slow] }

    expect(plans.map(&:used)).to eq([true, true])
    expect(plans.map { |p| index_names(p.raw_plan).first.sub(/\A<\d+>/, "") }.uniq.size).to eq(1)
    expect(plans[0].canonical_plan).not_to be_matches(plans[1].canonical_plan)
  end

  it "tests a rewrite candidate with the same call" do
    rewrite = "SELECT * FROM t WHERE a = $1 UNION SELECT * FROM t WHERE c = $2"
    report = run(rewrite, { slow: %w[5 9] }, [candidate(key: ["c"])])

    expect(report.results.first.plans[:slow].used).to be(true)
    expect(index_names(report.results.first.plans[:slow].raw_plan).size).to eq(1)
  end

  it "leaves no hypothetical index, prepared statement, transaction, or setting behind" do
    run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["a"]), candidate(key: ["c"])])

    expect(leftovers).to eq(clean)
  end

  it "leaves nothing behind when a literal fails" do
    expect { run("SELECT * FROM t WHERE a = $1", { slow: ["5"], bad: ["x"] }, [candidate(key: ["a"])]) }
      .to raise_error(described_class::Error)
    expect(leftovers).to eq(clean)
  end

  it "removes a hypothetical index the caller left, before the baseline" do
    conn.exec("SELECT * FROM hypopg_create_index('CREATE INDEX ON t (a)')")
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [])

    expect(report.baseline.plans[:slow].used).to be(false)
    expect(index_names(report.baseline.plans[:slow].raw_plan)).to eq([])
  end

  it "records a candidate HypoPG refuses by rule and SQLSTATE, and goes on to the next" do
    refused = candidate(key: ["a"], predicate: "s = '#{sentinel}'")
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [refused, candidate(key: ["a"])])

    expect(report.results[0].refusal)
      .to eq(described_class::Refusal.new(rule: :hypopg_refused, sqlstate: "22P02"))
    expect(report.results[0].size).to be_nil
    expect(report.results[0].plans).to eq({})
    expect(report.results[0].used?).to be(false)
    expect(report.results[1].used?).to be(true)
    expect(report.inspect).not_to include(sentinel)
    expect(leftovers).to eq(clean)
  end

  it "raises an error with a rule and SQLSTATE that never quotes a literal" do
    error = nil
    begin
      run("SELECT * FROM t WHERE a = $1", { slow: [sentinel] }, [candidate(key: ["a"])])
    rescue described_class::Error => e
      error = e
    end

    expect(error).to have_attributes(rule: :explain_failed, sqlstate: "22P02", cause: nil)
    expect(error.full_message).not_to include(sentinel)
    expect(error.message).to eq("explain_failed (SQLSTATE 22P02)")
  end

  it "keeps the raw plan's literals out of inspect" do
    report = run("SELECT * FROM t WHERE flag = $1", { slow: [sentinel] }, [candidate(key: ["flag"])])

    expect(JSON.generate(report.results.first.plans[:slow].raw_plan)).to include(sentinel)
    expect(JSON.generate(report.baseline.plans[:slow].raw_plan)).to include(sentinel)
    expect(report.inspect).not_to include(sentinel)
    expect(report.to_s).not_to include(sentinel)
  end

  it "drops notices during the run and puts the caller's receiver back" do
    conn.exec(<<~SQL)
      CREATE FUNCTION noisy(v text) RETURNS int IMMUTABLE LANGUAGE plpgsql AS $$
      BEGIN
        RAISE NOTICE 'saw %', v;
        RETURN 1;
      END $$;
    SQL
    heard = []
    conn.set_notice_receiver { |result| heard << result.error_message }
    run("SELECT * FROM t WHERE a = noisy($1)", { slow: [sentinel] }, [candidate(key: ["a"])])

    expect(heard).to eq([])
    conn.exec("SELECT noisy('after')")
    expect(heard.size).to eq(1)
    expect(heard.first).to include("saw after")
  end

  it "refuses to start inside the caller's transaction, and leaves it alone" do
    conn.exec("BEGIN")
    expect { run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["a"])]) }
      .to raise_error(described_class::Error, "in_transaction")
    expect(conn.transaction_status).not_to eq(0)
    conn.exec("ROLLBACK")
  end

  it "freezes its results" do
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["a"])])
    result = report.results.first

    expect([report, report.results, report.baseline, report.baseline.plans, result, result.plans,
            result.plans[:slow], result.plans[:slow].raw_plan, result.plans[:slow].raw_plan.first["Plan"]])
      .to all(be_frozen)
  end
end
