# frozen_string_literal: true

require "json"
require "quaack/enclave/canonical_plan"

# Real plans from the test harness's Postgres. The production plan in step 1
# comes from EXPLAIN (ANALYZE, BUFFERS, SETTINGS), and the racetrack plans
# steps 5, 5a-4, and 8 compare with it come from a plain EXPLAIN.
CANONICAL_PLAN_PRODUCTION = "EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)"
CANONICAL_PLAN_RACETRACK = "EXPLAIN (FORMAT JSON)"
CANONICAL_PLAN_JOIN = "SELECT c.name, o.total_cents FROM public.customers c JOIN public.orders o " \
                      "ON o.customer_id = c.id WHERE c.name = 'Ada Jones 8' AND o.total_cents > 1000 " \
                      "ORDER BY o.total_cents"

RSpec.describe Quaack::Enclave::CanonicalPlan do
  def explain(query, how = CANONICAL_PLAN_RACETRACK, settings: [])
    conn = test_database.connection
    conn.transaction do
      settings.each { |s| conn.exec("SET LOCAL #{s}") }
      JSON.parse(conn.exec("#{how} #{query}").getvalue(0, 0))
    end
  end

  def canonical(query, how = CANONICAL_PLAN_RACETRACK, settings: [])
    described_class.new(explain(query, how, settings:))
  end

  {
    "a join with a filter and a sort" => CANONICAL_PLAN_JOIN,
    "an InitPlan" => "SELECT c.name FROM public.customers c " \
                     "WHERE c.id = (SELECT o.customer_id FROM public.orders o WHERE o.total_cents = 5100 LIMIT 1)",
    "a hashed NOT IN" => "SELECT c.id FROM public.customers c " \
                         "WHERE c.id NOT IN (SELECT o.customer_id FROM public.orders o WHERE o.total_cents > 40000)",
    "a correlated SubPlan" => "SELECT c.name FROM public.customers c WHERE c.id < 200 AND " \
                              "(SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id) > 3",
    "a CTE and a subquery" => "WITH w AS MATERIALIZED (SELECT * FROM public.orders o " \
                              "WHERE o.status = 'shipped') SELECT sq.n FROM (SELECT w.customer_id, count(*) AS n " \
                              "FROM w GROUP BY w.customer_id) sq WHERE sq.n > 2 ORDER BY sq.n"
  }.each do |what, query|
    it "matches the production plan of #{what} with its racetrack plan" do
      production = canonical(query, CANONICAL_PLAN_PRODUCTION)
      expect(production.comparable?).to be(true)
      expect(production.matches?(canonical(query))).to be(true)
    end
  end

  it "matches the same query with other literals" do
    other = CANONICAL_PLAN_JOIN.sub("'Ada Jones 8'", "'Bo Smith 3'").sub("1000", "2500")
    expect(canonical(CANONICAL_PLAN_JOIN).matches?(canonical(other))).to be(true)
  end

  it "matches the same query with other aliases" do
    query = "WITH w AS MATERIALIZED (SELECT * FROM public.orders o WHERE o.status = 'shipped') " \
            "SELECT sq.n FROM (SELECT w.customer_id, count(*) AS n FROM w GROUP BY w.customer_id) sq " \
            "JOIN public.customers c ON c.id = sq.customer_id WHERE sq.n > 2 ORDER BY sq.n, c.name"
    renamed = query.gsub("sq", "totals").gsub(/\bo\b/, "ord").gsub(/\bc\b/, "cust")
    expect(canonical(query).matches?(canonical(renamed))).to be(true)
  end

  it "tells apart plans for the same query that the planner made differently" do
    nested_loop = canonical(CANONICAL_PLAN_JOIN, settings: ["enable_hashjoin = off", "enable_mergejoin = off"])
    hash_join = canonical(CANONICAL_PLAN_JOIN, settings: ["enable_nestloop = off", "enable_mergejoin = off"])
    expect(nested_loop.matches?(hash_join)).to be(false)
  end

  it "tells apart plans that use different indexes" do
    query = "SELECT o.id FROM public.orders o WHERE o.status = 'shipped' AND o.customer_id = 5"
    settings = ["enable_seqscan = off", "enable_bitmapscan = off"]
    before = explain(query, settings:)
    test_database.connection.exec("DROP INDEX public.orders_customer_id_idx")
    after = explain(query, settings:)
    expect([before, after].map { |p| p.dig(0, "Plan", "Index Name") })
      .to eq(%w[orders_customer_id_idx orders_status_created_at_idx])
    expect(described_class.new(before).matches?(described_class.new(after))).to be(false)
  end

  # Without a map, a name HypoPG made is kept, oid and all, since a real
  # index can have a name like that.
  it "tells apart plans that use the same hypothetical index under different oids without a map" do
    conn = test_database.connection
    conn.exec("CREATE EXTENSION hypopg")
    query = "SELECT o.id FROM public.orders o WHERE o.total_cents = 5100"
    # The second round makes another index first, so this one gets a new oid.
    plans = [[], ["CREATE INDEX ON public.customers (name)"]].map do |others|
      conn.exec("SELECT hypopg_reset()")
      [*others, "CREATE INDEX ON public.orders (total_cents)"].each do |ddl|
        conn.exec_params("SELECT * FROM hypopg_create_index($1)", [ddl])
      end
      explain(query)
    end
    names = plans.map { |p| p.dig(0, "Plan", "Index Name") }
    expect(names.uniq.size).to eq(2)
    expect(names).to all(end_with("btree_orders_total_cents"))
    expect(described_class.new(plans.first).matches?(described_class.new(plans.last))).to be(false)
  end

  # A quoted identifier can look like a name HypoPG makes. The step 1 plan
  # has no map, and the racetrack's has one for its hypothetical indexes,
  # none here, as step 5 compares them.
  describe "a real index named like a hypothetical one" do
    let(:query) { "SELECT o.id FROM public.orders o WHERE o.total_cents = 5100" }

    before do
      conn = test_database.connection
      conn.exec("CREATE EXTENSION hypopg")
      conn.exec('CREATE INDEX "<1>orders_total_cents" ON public.orders (total_cents)')
    end

    it "matches itself from production to the racetrack" do
      production = explain(query, CANONICAL_PLAN_PRODUCTION)
      racetrack = explain(query)
      expect(racetrack.dig(0, "Plan", "Index Name")).to eq("<1>orders_total_cents")
      expect(described_class.new(production)
               .matches?(described_class.new(racetrack, hypothetical_indexes: {}))).to be(true)
    end

    it "doesn't match another real index whose name is the rest of it" do
      conn = test_database.connection
      before = explain(query)
      conn.exec('DROP INDEX public."<1>orders_total_cents"')
      conn.exec("CREATE INDEX orders_total_cents ON public.orders (total_cents)")
      after = explain(query)
      expect(after.dig(0, "Plan", "Index Name")).to eq("orders_total_cents")
      expect(described_class.new(before).matches?(described_class.new(after))).to be(false)
      expect(described_class.new(before, hypothetical_indexes: {})
               .matches?(described_class.new(after, hypothetical_indexes: {}))).to be(false)
    end
  end

  # HypoPG names an index for its method, table, and columns only, so two
  # different indexes can get the same name. The caller maps each
  # hypothetical index's oid to what it is, here its definition.
  describe "hypothetical indexes mapped to what they are" do
    # The plan of query with only the hypothetical index ddl, and the oid to
    # definition map from HypoPG. Each of others is made first, after the
    # reset, so the index gets a later oid.
    def with_hypothetical(ddl, query, others: [])
      conn = test_database.connection
      conn.exec("CREATE EXTENSION IF NOT EXISTS hypopg")
      conn.exec("SELECT hypopg_reset()")
      others.each { conn.exec_params("SELECT * FROM hypopg_create_index($1)", [it]) }
      oid = Integer(conn.exec_params("SELECT indexrelid FROM hypopg_create_index($1)", [ddl]).getvalue(0, 0))
      definition = conn.exec_params("SELECT hypopg_get_indexdef($1)", [oid]).getvalue(0, 0)
      [explain(query, settings: ["enable_seqscan = off", "enable_bitmapscan = off"]), { oid => definition }]
    end

    before do
      test_database.connection.exec("DROP INDEX public.orders_status_created_at_idx")
    end

    {
      "a partial index and a plain one" => ["CREATE INDEX ON public.orders (status)",
                                            "CREATE INDEX ON public.orders (status) WHERE total_cents > 100"],
      "an index with a column and one that includes it" => [
        "CREATE INDEX ON public.orders (status, created_at)",
        "CREATE INDEX ON public.orders (status) INCLUDE (created_at)"
      ],
      "an ascending index and a descending one" => ["CREATE INDEX ON public.orders (status)",
                                                    "CREATE INDEX ON public.orders (status DESC)"]
    }.each do |what, (first, second)|
      it "tells apart #{what}, which HypoPG names the same" do
        # total_cents > 200 implies the partial index's predicate but stays
        # in the Filter, so the plans differ only in which index they use.
        query = "SELECT o.created_at FROM public.orders o WHERE o.status = 'shipped' AND o.total_cents > 200"
        (a, a_map), (b, b_map) = [first, second].map { |ddl| with_hypothetical(ddl, query) }
        names = [a, b].map { |p| p.dig(0, "Plan", "Index Name").sub(/\A<\d+>/, "") }
        expect(names.uniq.size).to eq(1)
        expect(described_class.new(a, hypothetical_indexes: a_map)
                 .matches?(described_class.new(b, hypothetical_indexes: b_map))).to be(false)
      end
    end

    it "matches the same hypothetical index made in two sessions" do
      query = "SELECT o.id FROM public.orders o WHERE o.status = 'shipped'"
      (a, a_map), (b, b_map) = [[], ["CREATE INDEX ON public.customers (name)"]].map do |others|
        with_hypothetical("CREATE INDEX ON public.orders (status) WHERE total_cents > 100", query, others:)
      end
      expect(a_map.keys).not_to eq(b_map.keys)
      expect(described_class.new(a, hypothetical_indexes: a_map)
               .matches?(described_class.new(b, hypothetical_indexes: b_map))).to be(true)
    end
  end
end
