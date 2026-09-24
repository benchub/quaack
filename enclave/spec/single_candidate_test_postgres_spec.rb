# frozen_string_literal: true

require "delegate"
require "json"
require "pp"
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

  # Postgres may switch a reused prepared statement to a generic plan after
  # five executions, and a generic plan wouldn't see a new hypothetical
  # index. "tests a query with no parameters" covers the other case, where
  # a reused statement always keeps its first plan.
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

  def run_error(query, literal_sets, candidates = [candidate(key: ["a"])], connection: conn)
    described_class.run(connection, query:, literal_sets:, candidates:)
    nil
  rescue described_class::Error => e
    e
  end

  it "refuses a query of more than one statement, so nothing can escape the rollback" do
    conn.exec("CREATE TABLE side (x int)")
    error = run_error("SELECT * FROM t WHERE a = $1; COMMIT; INSERT INTO side VALUES (1)", { slow: ["5"] })

    expect(error).to have_attributes(rule: :prepare_failed, sqlstate: "42601", cause: nil)
    expect(conn.exec("SELECT count(*) FROM side").getvalue(0, 0)).to eq("0")
    expect(leftovers).to eq(clean)
  end

  it "keeps an inline literal out of an error preparing the query" do
    error = run_error("SELECT * FROM t WHERE nope = '#{sentinel}' AND a = $1", { slow: ["5"] })

    expect(error).to have_attributes(rule: :prepare_failed, sqlstate: "42703", cause: nil)
    expect(error.full_message).not_to include(sentinel)
    expect(leftovers).to eq(clean)
  end

  it "tests a query with no parameters" do
    report = run("SELECT * FROM t WHERE a = 5", { slow: [] }, [candidate(key: ["a"])])

    expect(report.results.first.plans[:slow].used).to be(true)
    expect(report.baseline.plans[:slow].used).to be(false)
  end

  it "quotes literals the way Postgres reads them" do
    values = ["O'Brien", "a\\b"]
    report = run("SELECT * FROM t WHERE flag = $1 OR flag = $2", { slow: values }, [])
    inline = inline_explain("SELECT * FROM t WHERE flag = #{conn.escape_literal(values[0])} " \
                            "OR flag = #{conn.escape_literal(values[1])}")

    expect(inline.first["Plan"]["Filter"]).to include("O''Brien").and include("a\\b")
    expect(report.baseline.plans[:slow].raw_plan.first["Plan"]["Filter"]).to eq(inline.first["Plan"]["Filter"])
  end

  {
    "a value that isn't a String" => 5,
    "a String with invalid encoding" => "SENTINEL-5a4-7f3c\xFF".dup.force_encoding(Encoding::UTF_8),
    "a String with a NUL" => "SENTINEL-5a4-7f3c\0"
  }.each do |what, value|
    it "refuses #{what} before touching the database, without quoting it" do
      error = run_error("SELECT * FROM t WHERE flag = $1", { slow: ["ok"], bad: [value] })

      expect(error).to have_attributes(rule: :bad_literal, sqlstate: nil, cause: nil)
      expect(error.full_message).not_to include("SENTINEL")
      expect(conn.transaction_status).to eq(0)
    end
  end

  it "refuses literal sets that aren't a Hash of lists" do
    expect(run_error("SELECT * FROM t WHERE flag = $1", [["ok"]])).to have_attributes(rule: :bad_literal)
    expect(run_error("SELECT * FROM t WHERE flag = $1", { slow: "ok" })).to have_attributes(rule: :bad_literal)
  end

  # HypoPG reports a column that doesn't exist as an internal error, XX000.
  it "records a candidate on a column that doesn't exist as refused" do
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["nope"])])

    expect(report.results.first.refusal)
      .to eq(described_class::Refusal.new(rule: :hypopg_refused, sqlstate: "XX000"))
  end

  def failing_function(code)
    conn.exec(<<~SQL)
      CREATE FUNCTION failing() RETURNS int IMMUTABLE LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'failing' USING ERRCODE = '#{code}';
      END $$;
    SQL
  end

  # A failure while creating the index that says the session, not the
  # definition, is at fault isn't HypoPG refusing it, so the run stops.
  # The candidate's predicate raises the SQLSTATE when HypoPG reads it.
  {
    "a cancel" => "57014",
    "a deadlock" => "40P01",
    "too many connections" => "53300",
    "an I/O error" => "58030",
    "corrupt data" => "XX001",
    "a corrupt index" => "XX002",
    "an aborted transaction" => "25P02",
    "a lost connection" => "08006",
    "a lock timeout" => "55P03"
  }.each do |what, code|
    it "stops the run when creating an index fails with #{what} (#{code})" do
      failing_function(code)
      error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] },
                        [candidate(key: ["a"], predicate: "a = failing()"), candidate(key: ["a"])])

      expect(error).to have_attributes(rule: :hypopg_failed, sqlstate: code, cause: nil)
      expect(leftovers).to eq(clean)
    end
  end

  # 22025 and 42P08 hold 25 and 08 past their start, so they tell whether
  # the session-failure classes are matched only at the start.
  %w[22023 22025 42P08].each do |code|
    it "records an error in the definition that a function in the predicate raises (#{code}) as refused" do
      failing_function(code)
      report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] },
                   [candidate(key: ["a"], predicate: "a = failing()")])

      expect(report.results.first.refusal)
        .to eq(described_class::Refusal.new(rule: :hypopg_refused, sqlstate: code))
    end
  end

  # HypoPG keeps hidden real indexes for the session, and hypopg_reset
  # doesn't unhide them, so the baseline and every candidate would plan
  # without the index.
  it "refuses to run while HypoPG hides an index, and leaves it hidden" do
    conn.exec("CREATE INDEX t_a_real ON t (a)")
    conn.exec("SELECT hypopg_hide_index('t_a_real'::regclass)")
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["b"])])

    expect(error).to have_attributes(rule: :indexes_hidden, sqlstate: nil, cause: nil, message: "indexes_hidden")
    expect(conn.exec("SELECT count(*) FROM hypopg_hidden_indexes()").getvalue(0, 0)).to eq("1")
    expect(leftovers).to eq(clean)
  end

  # The run's reset removes a hidden hypothetical index, so it hides
  # nothing by the time the run checks.
  it "runs when the caller left a hidden hypothetical index" do
    oid = conn.exec("SELECT indexrelid FROM hypopg_create_index('CREATE INDEX ON public.t (a)')").getvalue(0, 0)
    conn.exec_params("SELECT hypopg_hide_index($1::oid)", [oid])
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["a"])])

    expect(report.results.first.used?).to be(true)
    expect(leftovers).to eq(clean)
  end

  # The run won't replace or drop a statement it didn't prepare.
  it "fails closed when the session already has a statement by the run's name, and leaves it" do
    conn.exec("PREPARE quaack_5a4 AS SELECT 1")
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] })

    expect(error).to have_attributes(rule: :prepare_failed, sqlstate: "42P05", cause: nil)
    expect(conn.exec("SELECT statement FROM pg_prepared_statements").values)
      .to eq([["PREPARE quaack_5a4 AS SELECT 1"]])
    expect(conn.exec("EXECUTE quaack_5a4").getvalue(0, 0)).to eq("1")
  end

  # A real index can have a name that looks like a hypothetical one.
  it "doesn't count a real index named like a hypothetical one as the candidate" do
    conn.exec('CREATE INDEX "<1>t_a" ON t (a)')
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["c"])])

    expect(index_names(report.results.first.plans[:slow].raw_plan)).to eq(["<1>t_a"])
    expect(report.results.first.used?).to be(false)
  end

  it "plans a join deeper than JSON's default nesting limit" do
    joins = (1...60).map { |i| "JOIN public.t t#{i} ON t#{i}.a = t#{i - 1}.b" }.join(" ")
    report = run("SELECT t0.c FROM public.t t0 #{joins} WHERE t0.a = $1", { slow: ["5"] }, [candidate(key: ["a"])])
    plan = report.results.first.plans[:slow]

    expect(plan.used).to be(true)
    expect(plan.total_cost).to be_a(Float).and(be_positive)
    expect(plan.canonical_plan).to be_comparable
    expect(plan.canonical_plan).not_to be_matches(report.baseline.plans[:slow].canonical_plan)
    expect(plan.raw_plan).to be_frozen
  end

  it "turns EXPLAIN output that isn't JSON into an error" do
    garbled = Class.new(SimpleDelegator) do
      def exec(sql, *)
        return Struct.new(:text) { def getvalue(*) = text }.new("[{SENTINEL-5a4-7f3c") if sql.start_with?("EXPLAIN")

        super
      end
    end
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, connection: garbled.new(conn))

    expect(error).to have_attributes(rule: :explain_failed, sqlstate: nil, cause: nil)
    expect(error.full_message).not_to include("SENTINEL")
    expect(leftovers).to eq(clean)
  end

  # Whether the candidate on s was used for each literal set, and the
  # Filters of the baseline's slow plan and the candidate's worst plan. A
  # generic plan can't see the literal, so every literal set would plan
  # alike, and each Filter would read (s = $1).
  def skewed_summary(connection)
    report = described_class.run(connection, query: "SELECT * FROM t WHERE s = $1",
                                             literal_sets: { slow: ["10"], worst: ["0"] },
                                             candidates: [candidate(key: ["s"])])
    plans = report.results.first.plans
    { used: plans.transform_values(&:used), filters: filters(report.baseline.plans[:slow], plans[:worst]) }
  end

  def filters(*plans) = plans.map { |p| p.raw_plan.first["Plan"]["Filter"] }

  let(:custom_plans) { { used: { slow: true, worst: false }, filters: ["(s = 10)", "(s = 0)"] } }

  it "plans each literal with a custom plan when the session asks for generic plans" do
    conn.exec("SET plan_cache_mode = force_generic_plan")
    expect(skewed_summary(conn)).to eq(custom_plans)
    expect(conn.exec("SHOW plan_cache_mode").getvalue(0, 0)).to eq("force_generic_plan")
  end

  # test_database is this example's own database, so the setting reaches
  # no other example.
  it "plans each literal with a custom plan when the database asks for generic plans" do
    conn.exec("ALTER DATABASE #{conn.escape_identifier(test_database.name)} SET plan_cache_mode = force_generic_plan")
    other = test_database.connect
    expect(other.exec("SHOW plan_cache_mode").getvalue(0, 0)).to eq("force_generic_plan")
    expect(skewed_summary(other)).to eq(custom_plans)
  ensure
    other&.close
  end

  # With hypopg.enabled off, HypoPG still creates the index and sizes it,
  # but the planner never sees it.
  it "turns HypoPG on for the run when the session has it off" do
    conn.exec("SET hypopg.enabled = off")
    expect(skewed_summary(conn)).to eq(custom_plans)
    expect(conn.exec("SHOW hypopg.enabled").getvalue(0, 0)).to eq("off")
  end

  it "turns HypoPG on for the run when the database has it off" do
    conn.exec("ALTER DATABASE #{conn.escape_identifier(test_database.name)} SET hypopg.enabled = off")
    other = test_database.connect
    expect(other.exec("SHOW hypopg.enabled").getvalue(0, 0)).to eq("off")
    expect(skewed_summary(other)).to eq(custom_plans)
  ensure
    other&.close
  end

  # A Postgres error with no SQLSTATE, such as a failure to send, says the
  # connection is at fault. The wrapper fails the create call that way.
  it "stops the run when creating an index fails with no SQLSTATE" do
    unsendable = Class.new(SimpleDelegator) do
      def exec_params(*) = raise(PG::UnableToSend, "SENTINEL-5a4-7f3c")
    end
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, connection: unsendable.new(conn))

    expect(error).to have_attributes(rule: :hypopg_failed, sqlstate: nil, cause: nil)
    expect(error.full_message).not_to include("SENTINEL")
    expect(leftovers).to eq(clean)
  end

  # hypopg_reset can't be found, so start fails, and then cleanup fails
  # the same way.
  it "raises the first error when cleanup fails too" do
    conn.exec("SET search_path = pg_catalog")
    error = run_error("SELECT * FROM public.t WHERE a = $1", { slow: ["5"] })
    conn.exec("RESET search_path")

    expect(error).to have_attributes(rule: :explain_failed, sqlstate: "42883", cause: nil)
    expect(leftovers).to eq(clean)
  end

  # The wrapper fails only the last hypopg_reset, which cleanup runs after
  # the rollback.
  it "raises a cleanup failure after a run that otherwise worked" do
    last_reset_fails = Class.new(SimpleDelegator) do
      def exec(sql, *)
        raise PG::UnableToSend, "no" if sql.include?("hypopg_reset") && transaction_status.zero?

        super
      end
    end
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, connection: last_reset_fails.new(conn))

    expect(error).to have_attributes(rule: :cleanup_failed, sqlstate: nil, cause: nil)
  end

  it "doesn't count a real index the plan uses as the candidate" do
    conn.exec("CREATE INDEX t_a_real ON t (a)")
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["c"])])

    expect(index_names(report.results.first.plans[:slow].raw_plan)).to eq(["t_a_real"])
    expect(report.results.first.used?).to be(false)
  end

  it "puts the caller's notice receiver back even when cleanup fails" do
    other = test_database.connect
    other.exec(<<~SQL)
      CREATE FUNCTION die(v text) RETURNS int IMMUTABLE LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_terminate_backend(pg_backend_pid());
        RETURN 1;
      END $$;
    SQL
    mine = proc {}
    other.set_notice_receiver(&mine)
    error = run_error("SELECT * FROM t WHERE a = die($1)", { slow: ["5"] }, connection: other)

    expect(error).to be_a(described_class::Error)
    expect(other.set_notice_receiver { nil }).to be(mine)
  ensure
    other&.close
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

  def session(query, literal_sets, &) = described_class.session(conn, query:, literal_sets:, &)

  it "measures with no hypothetical index when a session measures none after one" do
    plans = session("SELECT * FROM t WHERE a = $1", { slow: ["5"] }) do |s|
      s.measure([candidate(key: ["a"])])
      s.measure([]).plans
    end

    expect(index_names(plans[:slow].raw_plan)).to eq([])
    expect(plans[:slow].used).to eq([])
  end

  # The wrapper swaps the second hypopg_reset in the transaction, the one
  # the baseline's measurement runs after start's, for SQL whose error
  # message quotes the sentinel.
  it "turns a failure resetting HypoPG before a measurement into an error that quotes nothing" do
    reset_fails = Class.new(SimpleDelegator) do
      def exec(sql, *)
        if sql.include?("hypopg_reset") && !transaction_status.zero? && (@resets = (@resets || 0) + 1) == 2
          return super("SELECT 'SENTINEL-5a4-7f3c'::int")
        end

        super
      end
    end
    error = run_error("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, connection: reset_fails.new(conn))

    expect(error).to have_attributes(rule: :hypopg_failed, sqlstate: "22P02", cause: nil)
    expect(error.full_message).not_to include("SENTINEL")
    expect(leftovers).to eq(clean)
  end

  # The wrapper records every call that could send SQL once the block has
  # ended.
  it "refuses to measure after the session's block has ended, without touching the database" do
    recording = Class.new(SimpleDelegator) do
      attr_accessor :calls

      %i[exec exec_params prepare].each do |name|
        define_method(name) do |*args|
          calls&.push(name)
          super(*args)
        end
      end
    end.new(conn)
    escaped = described_class.session(recording, query: "SELECT * FROM t WHERE a = $1",
                                                 literal_sets: { slow: ["5"] }) { |s| s }
    recording.calls = []
    error = nil
    begin
      escaped.measure([candidate(key: ["a"])])
    rescue described_class::Error => e
      error = e
    end

    expect(error).to have_attributes(rule: :session_closed, sqlstate: nil, cause: nil)
    expect(recording.calls).to eq([])
    expect(leftovers).to eq(clean)
  end

  it "keeps the raw plan's literals out of a Measurement's inspect" do
    measurement = session("SELECT * FROM t WHERE flag = $1", { slow: [sentinel] }) do |s|
      s.measure([candidate(key: ["flag"])])
    end
    measured = measurement.plans[:slow]
    shown = [measurement, measured].flat_map { |v| [v.inspect, v.to_s, v.pretty_inspect] }

    expect(JSON.generate(measured.raw_plan)).to include(sentinel)
    expect(measured.used).to eq([true])
    expect(shown).to all(satisfy { |text| !text.include?(sentinel) })
  end

  it "freezes its results" do
    report = run("SELECT * FROM t WHERE a = $1", { slow: ["5"] }, [candidate(key: ["a"])])
    result = report.results.first

    expect([report, report.results, report.baseline, report.baseline.plans, result, result.plans,
            result.plans[:slow], result.plans[:slow].raw_plan, result.plans[:slow].raw_plan.first["Plan"]])
      .to all(be_frozen)
  end
end
