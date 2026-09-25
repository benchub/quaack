# frozen_string_literal: true

require "json"
require "quaack/enclave/canonical_plan"

# The fixtures are real Postgres 18 output of EXPLAIN (ANALYZE, BUFFERS,
# SETTINGS, FORMAT JSON), captured by spec/fixtures/plans/capture.rb.

CANONICAL_PLAN_FIXTURES = Dir[File.join(__dir__, "fixtures", "plans", "*.json")]
                          .map { |f| File.basename(f, ".json") }.sort.freeze

# The fields a plain EXPLAIN (FORMAT JSON) doesn't print: actual rows,
# timings, buffers, workers, and the like.
CANONICAL_PLAN_MEASURED = /\A#{Regexp.union(
  "Actual ", "Rows Removed", "Shared ", "Local ", "Temp ", "Heap ", "Exact ", "Lossy ", "Hash B", "Original ",
  "Peak ", "Sort Sp", "Sort M", "Workers", "Disk", "HashAgg", "Full-sort", "Pre-sorted", "Storage", "Maximum",
  "Index Searches"
)}/

RSpec.describe Quaack::Enclave::CanonicalPlan do
  def plan(name) = JSON.parse(File.read(File.join(__dir__, "fixtures", "plans", "#{name}.json")))

  def canonical(explain) = described_class.new(explain)

  # A deep copy of a fixture, with its top plan node yielded for changes.
  def changed(name)
    explain = plan(name)
    yield explain.first["Plan"]
    explain
  end

  def nodes(node) = [node, *node.fetch("Plans", []).flat_map { |child| nodes(child) }]

  # Every number in the plan, costs and timings and counts alike, is changed,
  # and the Workers lists are emptied.
  def remeasured(name)
    explain = plan(name)
    explain.first.merge!("Planning Time" => 99.0, "Execution Time" => 99.0, "Planning" => {}, "Settings" => {})
    nodes(explain.first["Plan"]).each do |node|
      node.each { |key, value| node[key] = (value * 3) + 7 if value.is_a?(Numeric) }
      node["Workers"] = [] if node.key?("Workers")
    end
    explain
  end

  # What a plain EXPLAIN (FORMAT JSON) prints: no actual rows, timings,
  # buffers, workers, or settings.
  def plain(name)
    explain = plan(name)
    explain.first.select! { |key, _| key == "Plan" }
    nodes(explain.first["Plan"]).each { |node| node.reject! { |key, _| key.match?(CANONICAL_PLAN_MEASURED) } }
    explain
  end

  describe "plans that differ only in measurements" do
    CANONICAL_PLAN_FIXTURES.each do |name|
      it "matches #{name} with every cost, row count, timing, and buffer count changed" do
        expect(canonical(plan(name)).matches?(canonical(remeasured(name)))).to be(true)
      end

      it "matches #{name} with a plain EXPLAIN of it" do
        expect(canonical(plan(name)).matches?(canonical(plain(name)))).to be(true)
      end
    end
  end

  # The fixture with every alias renamed, in the Alias fields and in the
  # qualifiers of every qual and key.
  def realiased(name, renames)
    explain = plan(name)
    nodes(explain.first["Plan"]).each do |node|
      node["Alias"] = renames.fetch(node["Alias"]) if node.key?("Alias")
      qualified_keys(node).each { |key| node[key] = rename_qualifiers(node[key], renames) }
    end
    explain
  end

  def qualified_keys(node) = (described_class::QUALS + described_class::SORT_KEYS).select { |key| node.key?(key) }

  def rename_qualifiers(texts, renames)
    pattern = /\b(#{renames.keys.join("|")})\./
    Array(texts).map { |text| text.gsub(pattern) { "#{renames.fetch(Regexp.last_match(1))}." } }
                .then { |renamed| texts.is_a?(Array) ? renamed : renamed.first }
  end

  def with_filter(name, filter) = changed(name) { |top| top["Filter"] = filter }

  def same?(left, right) = canonical(left).matches?(canonical(right))

  describe "plans that differ only in literals" do
    it "matches quals whose string literals differ" do
      expect(same?(plan("seq_scan_rare_value"),
                   with_filter("seq_scan_rare_value", "((total_cents > 100) AND (status = 'shipped'::text))")))
        .to be(true)
    end

    it "matches quals whose numbers and timestamps differ" do
      expect(same?(with_filter("seq_scan_rare_value", "((total_cents > 100) AND (created_at > '2026-01-01'::date))"),
                   with_filter("seq_scan_rare_value", "((total_cents > 99999) AND (created_at > '1999-12-31'::date))")))
        .to be(true)
    end

    it "matches a qual with a literal and one with a parameter" do
      expect(same?(with_filter("seq_scan_parameter", "((status = 'shipped'::text) AND (total_cents = 5100))"),
                   plan("seq_scan_parameter"))).to be(true)
    end

    it "matches IN lists of different lengths" do
      expect(same?(with_filter("seq_scan_rare_value", "(total_cents = ANY ('{1,2}'::integer[]))"),
                   with_filter("seq_scan_rare_value", "(total_cents = ANY ('{1,2,3,4}'::integer[]))"))).to be(true)
    end

    it "matches sort keys whose literals differ" do
      a = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["status", "(total_cents + 1)"] }
      b = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["status", "(total_cents + 2)"] }
      expect(same?(a, b)).to be(true)
    end
  end

  # The racetrack runs 3h's anchored query, so its plan prints
  # quaack.clock_anchor() where production's printed now() and the like.
  # These are the texts Postgres 18 prints, plain and VERBOSE.
  describe "clock functions and 3h's anchor" do
    {
      "(created_at > now())" => "(created_at > quaack.clock_anchor())",
      "(orders.created_at > transaction_timestamp())" => "(orders.created_at > quaack.clock_anchor())",
      "(created_at > statement_timestamp())" => "(created_at > quaack.clock_anchor())",
      "(created_at > CURRENT_TIMESTAMP)" => "(created_at > quaack.clock_anchor())",
      "(created_at > (CURRENT_DATE - 7))" => "(created_at > ((quaack.clock_anchor())::date - 7))",
      "(created_at > LOCALTIMESTAMP(2))" => "(created_at > (quaack.clock_anchor())::timestamp(2) without time zone)",
      "(created_at > CURRENT_TIMESTAMP(3))" => "(created_at > (quaack.clock_anchor())::timestamp(3) with time zone)",
      "(created_at > pg_catalog.now())" => "(created_at > quaack.clock_anchor())"
    }.each do |production, racetrack|
      it "matches #{production} with #{racetrack}" do
        expect(same?(with_filter("seq_scan_rare_value", production), with_filter("seq_scan_rare_value", racetrack)))
          .to be(true)
      end
    end

    it "doesn't match a clock function with the anchor cast to another type" do
      expect(same?(with_filter("seq_scan_rare_value", "(created_at > (CURRENT_DATE - 7))"),
                   with_filter("seq_scan_rare_value", "(created_at > ((quaack.clock_anchor())::time - 7))")))
        .to be(false)
    end

    it "doesn't match another schema's now() with the anchor" do
      expect(same?(with_filter("seq_scan_rare_value", "(created_at > app.now())"),
                   with_filter("seq_scan_rare_value", "(created_at > quaack.clock_anchor())"))).to be(false)
    end

    it "doesn't match clock_timestamp() with the anchor" do
      expect(same?(with_filter("seq_scan_rare_value", "(created_at > clock_timestamp())"),
                   with_filter("seq_scan_rare_value", "(created_at > quaack.clock_anchor())"))).to be(false)
    end
  end

  describe "plans that differ only in aliases" do
    it "matches a plan with every alias renamed" do
      expect(same?(plan("nested_loop_parameterized"),
                   realiased("nested_loop_parameterized", "c" => "cust", "o" => "ord"))).to be(true)
    end

    it "matches a plan with two tables' aliases swapped" do
      %w[seq_scan_most_rows merge_join_filter sort_two_tables group_aggregate_two_tables].each do |name|
        expect(same?(plan(name), realiased(name, "c" => "o", "o" => "c"))).to be(true), name
      end
    end

    # VERBOSE qualifies every column, even in a scan's own quals, and adds
    # Output and Schema.
    it "matches a VERBOSE plan with the same plan without VERBOSE" do
      expect(same?(plan("seq_scan_most_rows"), plan("seq_scan_most_rows_verbose"))).to be(true)
    end

    it "matches a bitmap index scan's bare column with the heap scan's qualified one" do
      verbose = changed("bitmap_and") do |top|
        top["Recheck Cond"] = "((o.customer_id < 200) AND (o.id < 2000))"
        top["Plans"].first["Plans"].first["Index Cond"] = "(o.customer_id < 200)"
      end
      expect(same?(plan("bitmap_and"), verbose)).to be(true)
    end

    # The SubPlan's bitmap index scan on o sits in a plan with two tables.
    it "matches a bitmap index scan's bare column with a qualified one in a plan with two tables" do
      verbose = changed("sub_plan") do |top|
        top["Plans"].first["Plans"].first["Plans"].first["Index Cond"] = "(o.customer_id = c.id)"
      end
      expect(same?(plan("sub_plan"), verbose)).to be(true)
    end

    # Scans with no relation, such as Subquery Scans, stand for their place
    # in the plan.
    it "tells apart quals that name two unnamed scans the other way round" do
      unnamed = lambda do |join_filter|
        changed("merge_join_filter") do |top|
          top["Join Filter"] = join_filter
          top["Plans"].each { |scan| scan.merge!("Node Type" => "Subquery Scan").delete("Relation Name") }
        end
      end
      expect(same?(unnamed.call("(o.status = c.name)"), unnamed.call("(c.status = o.name)"))).to be(false)
      expect(same?(unnamed.call("(o.status = c.name)"), unnamed.call("(o.status = c.name)"))).to be(true)
    end

    # Postgres qualifies a key above the scan in some single-table plans and
    # not in others.
    it "matches a bare column with a qualified one in a plan with one table" do
      qualified = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["o.status", "o.total_cents"] }
      expect(same?(plan("incremental_sort"), qualified)).to be(true)
    end

    it "tells a bare column above the scans from a qualified one in a plan with two tables" do
      bare = changed("merge_join_filter") { |top| top["Join Filter"] = "(status = c.name)" }
      expect(same?(plan("merge_join_filter"), bare)).to be(false)
    end

    # The SubPlan's Aggregate sits under the scan of c, but reads from o.
    it "doesn't give a bare column in a node under a scan to that scan's table" do
      bare = changed("sub_plan") { |top| top["Plans"].first["Group Key"] = ["customer_id"] }
      qualified = changed("sub_plan") { |top| top["Plans"].first["Group Key"] = ["c.customer_id"] }
      expect(same?(bare, qualified)).to be(false)
    end

    it "tells a scan's bare column from another table's qualified one" do
      other = changed("seq_scan_rare_value") do |top|
        top["Filter"] = "((c.total_cents > 100) AND (status = 'x'::text))"
      end
      expect(same?(plan("seq_scan_rare_value"), other)).to be(false)
    end

    it "still tells apart quals that name the tables the other way round" do
      a = changed("merge_join_filter") { |top| top["Join Filter"] = "(o.status = c.name)" }
      b = changed("merge_join_filter") { |top| top["Join Filter"] = "(c.status = o.name)" }
      expect(same?(a, b)).to be(false)
    end

    it "still tells apart a column of an alias the plan doesn't scan" do
      a = changed("merge_join_filter") { |top| top["Join Filter"] = "(o.status = c.name)" }
      b = changed("merge_join_filter") { |top| top["Join Filter"] = "(o.status = x.name)" }
      expect(same?(a, b)).to be(false)
    end
  end

  # Postgres prints references to InitPlans and SubPlans in forms that aren't
  # SQL. These are the forms Postgres 18's ruleutils.c prints.
  describe "quals that refer to subplans" do
    {
      "an InitPlan's output" => "(id = (InitPlan 1).col1)",
      "a scalar SubPlan" => "(total_cents > (SubPlan 1))",
      "a hashed NOT IN" => "(NOT (ANY (id = (hashed SubPlan 1).col1)))",
      "an unhashed ANY" => "(ANY (id = (SubPlan 1).col1))",
      "an ALL" => "(ALL (total_cents > (SubPlan 1).col1))",
      "an EXISTS" => "(EXISTS(SubPlan 1) OR (total_cents = 2))",
      "a hashed EXISTS" => "EXISTS(hashed SubPlan 1)",
      "an ARRAY" => "(total_cents = ANY (ARRAY(SubPlan 1)))",
      "a rescan" => "(rescan SubPlan 1)"
    }.each do |what, filter|
      it "compares a qual with #{what}" do
        a = canonical(with_filter("seq_scan_rare_value", filter))
        expect(a.comparable?).to be(true)
        expect(a.matches?(canonical(with_filter("seq_scan_rare_value", filter)))).to be(true)
        expect(a.matches?(canonical(with_filter("seq_scan_rare_value", "(id = 5)")))).to be(false)
      end
    end

    {
      "subplans" => ["(id = (InitPlan 1).col1)", "(id = (InitPlan 2).col1)"],
      "subplan columns" => ["(id = (InitPlan 1).col1)", "(id = (InitPlan 1).col2)"],
      "InitPlans and SubPlans" => ["(id = (InitPlan 1).col1)", "(id = (SubPlan 1).col1)"],
      "hashed and unhashed subplans" => ["(ANY (id = (hashed SubPlan 1).col1))", "(ANY (id = (SubPlan 1).col1))"],
      "ANY and ALL" => ["(ANY (id = (SubPlan 1).col1))", "(ALL (id = (SubPlan 1).col1))"],
      "IN and NOT IN" => ["(ANY (id = (hashed SubPlan 1).col1))", "(NOT (ANY (id = (hashed SubPlan 1).col1)))"],
      "EXISTS and ARRAY" => ["(id = EXISTS(SubPlan 1))", "(id = ARRAY(SubPlan 1))"]
    }.each do |what, (a, b)|
      it "tells #{what} apart" do
        expect(same?(with_filter("seq_scan_rare_value", a), with_filter("seq_scan_rare_value", b))).to be(false)
      end
    end
  end

  # A qual that doesn't parse can't be compared. Rather than guess, the whole
  # plan is marked as not comparable, and it matches no plan, not even itself.
  describe "a qual that doesn't parse" do
    let(:broken) { with_filter("seq_scan_rare_value", "(status = 'quaack-sentinel-email' +* )") }

    it "makes the plan not comparable" do
      expect(canonical(broken).comparable?).to be(false)
      expect(canonical(plan("seq_scan_rare_value")).comparable?).to be(true)
    end

    it "makes the plan match nothing, not even the same plan" do
      expect(same?(broken, broken)).to be(false)
      expect(same?(plan("seq_scan_rare_value"), broken)).to be(false)
    end

    it "treats a sort key the same way" do
      explain = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["status +* "] }
      expect(canonical(explain).comparable?).to be(false)
    end

    it "treats a qual that closes its clause and adds more the same way" do
      explain = with_filter("seq_scan_rare_value", "(id = 5) ORDER BY id")
      expect(canonical(explain).comparable?).to be(false)
    end

    it "treats a qual that parses as two statements the same way" do
      expect(canonical(with_filter("seq_scan_rare_value", "(id = 5); SELECT 1")).comparable?).to be(false)
    end

    it "treats a qual with a NUL byte the same way, without raising" do
      expect(canonical(with_filter("seq_scan_rare_value", "(email = 'quaack-sentinel\0email')")).comparable?)
        .to be(false)
    end

    it "treats a sort key with a NUL byte the same way, without raising" do
      explain = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["status", "(x || '\0')"] }
      expect(canonical(explain).comparable?).to be(false)
    end

    it "treats a qual that isn't valid UTF-8 the same way, without raising" do
      expect(canonical(with_filter("seq_scan_rare_value", "(email = '\xFF(ANY ')")).comparable?).to be(false)
    end

    it "treats a sort key that adds a second key the same way" do
      explain = changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = ["status, id"] }
      expect(canonical(explain).comparable?).to be(false)
    end

    it "doesn't keep the qual's text or quote it in an error" do
      expect(Marshal.dump(canonical(broken))).not_to include("quaack-sentinel")
    end
  end

  # Each session gives a hypothetical index a new oid, which HypoPG puts at
  # the front of its name.
  describe "hypothetical indexes" do
    def hypothetical(name) = changed("primary_key_lookup") { |top| top["Index Name"] = name }

    it "matches the same hypothetical index with another oid" do
      expect(same?(hypothetical("<13542>btree_orders_total_cents"), hypothetical("<16901>btree_orders_total_cents")))
        .to be(true)
    end

    def mapped(name, map) = canonical_with(hypothetical(name), map)

    def canonical_with(explain, map) = described_class.new(explain, hypothetical_indexes: map)

    it "tells apart hypothetical indexes with one name that the caller maps to different identities" do
      expect(mapped("<13542>btree_orders_status", 13_542 => "CREATE INDEX ON orders (status)")
        .matches?(mapped("<13542>btree_orders_status", 13_542 => "CREATE INDEX ON orders (status DESC)")))
        .to be(false)
    end

    it "matches hypothetical indexes with different oids that the caller maps to one identity" do
      expect(mapped("<13542>btree_orders_status", 13_542 => "CREATE INDEX ON orders (status)")
        .matches?(mapped("<16901>btree_orders_status", 16_901 => "CREATE INDEX ON orders (status)"))).to be(true)
    end

    it "tells a mapped hypothetical index from a real index whose name is its identity" do
      real = canonical(plan("primary_key_lookup"))
      expect(mapped("<13542>btree_orders_status", 13_542 => "orders_pkey").matches?(real)).to be(false)
    end

    it "makes a plan with a hypothetical index the map leaves out not comparable" do
      expect(mapped("<13542>btree_orders_status", 99 => "CREATE INDEX ON orders (status)").comparable?).to be(false)
      expect(mapped("<13542>btree_orders_status", 13_542 => "CREATE INDEX ON orders (status)").comparable?).to be(true)
    end

    it "leaves real indexes as they are when there's a map" do
      expect(canonical_with(plan("primary_key_lookup"), 13_542 => "x").matches?(canonical(plan("primary_key_lookup"))))
        .to be(true)
    end

    it "holds no identity, since a partial index's predicate holds a literal" do
      map = { 13_542 => "CREATE INDEX ON orders (status) WHERE email = 'quaack-sentinel-email'" }
      expect(Marshal.dump(mapped("<13542>btree_orders_status", map))).not_to include("quaack-sentinel")
    end

    [["not a hash"], { "13542" => "x" }, { 13_542 => :x }].each do |map|
      it "rejects hypothetical_indexes #{map.inspect.dump} without quoting it" do
        expect { mapped("<13542>btree_orders_status", map) }
          .to raise_error(ArgumentError, "hypothetical_indexes must map index oids to identity strings")
      end
    end

    it "tells two hypothetical indexes apart" do
      expect(same?(hypothetical("<13542>btree_orders_total_cents"), hypothetical("<13542>btree_orders_status")))
        .to be(false)
    end
  end

  describe "input" do
    ["not a plan", [], [{}], [{ "Plan" => [] }], ["Plan"]].each do |explain|
      it "rejects #{explain.inspect} without quoting it" do
        expect do
          canonical(explain)
        end.to raise_error(ArgumentError, "explain must be the parsed JSON of EXPLAIN (FORMAT JSON)")
      end
    end

    it "makes a plan with a qual that isn't text not comparable" do
      expect(canonical(with_filter("seq_scan_rare_value", 5)).comparable?).to be(false)
    end

    it "makes a plan with sort keys that aren't a list of text not comparable" do
      expect(canonical(changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = "status" }).comparable?)
        .to be(false)
      expect(canonical(changed("incremental_sort") { |top| top["Plans"].first["Sort Key"] = [5] }).comparable?)
        .to be(false)
    end

    it "gives a frozen plan that later changes to the explain don't reach" do
      explain = plan("seq_scan_rare_value")
      canonical = canonical(explain)
      explain.first["Plan"]["Filter"] = "(id = 5)"
      expect(canonical).to be_frozen
      expect(canonical.matches?(canonical(plan("seq_scan_rare_value")))).to be(true)
    end
  end

  describe "the trust boundary" do
    let(:sentinels) { %w[quaack-sentinel-email quaack-sentinel-name] }

    it "keeps the qual that holds the literals" do
      expect(plan("sentinel_literals").first.dig("Plan", "Filter")).to include(*sentinels)
      expect(same?(plan("sentinel_literals"), with_filter("sentinel_literals", "(email = 'x'::text)"))).to be(false)
    end

    it "holds no literal from a qual" do
      dumped = Marshal.dump(canonical(plan("sentinel_literals")))
      shown = canonical(plan("sentinel_literals")).then { |c| [c.inspect, c.to_s] }.join
      sentinels.each do |sentinel|
        expect(dumped).not_to include(sentinel)
        expect(shown).not_to include(sentinel)
      end
    end

    it "holds no literal from a sort key" do
      explain = changed("incremental_sort") do |top|
        top["Plans"].first["Sort Key"] = ["('quaack-sentinel-email' || status)"]
      end
      expect(Marshal.dump(canonical(explain))).not_to include("quaack-sentinel-email")
    end
  end

  describe "plans that differ in what the planner chose" do
    def differs(name, &)
      expect(canonical(plan(name)).matches?(canonical(changed(name, &)))).to be(false)
    end

    it "matches itself, so the changes below are what make them differ" do
      expect(canonical(plan("nested_loop_parameterized")).matches?(canonical(plan("nested_loop_parameterized"))))
        .to be(true)
    end

    it "tells node types apart" do
      differs("primary_key_lookup") { |top| top["Node Type"] = "Index Only Scan" }
    end

    it "tells a parallel scan from a plain one" do
      differs("parallel_hash_join") { |top| nodes(top).find { |n| n["Parallel Aware"] }["Parallel Aware"] = false }
    end

    it "tells relations apart" do
      differs("seq_scan_rare_value") { |top| top["Relation Name"] = "customers" }
    end

    # With no qual to name the relation's columns, only Relation Name tells
    # the scans apart.
    it "tells relations apart in scans without quals" do
      a = changed("primary_key_lookup") { |top| top.delete("Index Cond") }
      b = changed("primary_key_lookup") { |top| top.delete("Index Cond") && top["Relation Name"] = "customers" }
      expect(canonical(a).matches?(canonical(b))).to be(false)
    end

    it "tells indexes apart" do
      differs("primary_key_lookup") { |top| top["Index Name"] = "orders_customer_id_idx" }
    end

    it "tells join types apart" do
      differs("nested_loop_parameterized") { |top| top["Join Type"] = "Left" }
    end

    it "tells aggregate strategies apart" do
      differs("hash_aggregate") { |top| top["Strategy"] = "Sorted" }
    end

    it "tells partial aggregates from final ones" do
      differs("parallel_hash_join") { |top| top["Partial Mode"] = "Partial" }
    end

    it "tells scan directions apart" do
      differs("primary_key_lookup") { |top| top["Scan Direction"] = "Backward" }
    end

    it "tells a join's sides apart" do
      differs("nested_loop_parameterized") { |top| top["Plans"].reverse! }
    end

    it "tells a node's relationship to its parent apart" do
      differs("init_plan") { |top| top["Plans"].first["Parent Relationship"] = "SubPlan" }
    end

    it "tells subplans apart" do
      differs("init_plan") { |top| top["Plans"].first["Subplan Name"] = "InitPlan 2" }
    end

    it "tells CTEs and functions apart" do
      a = changed("seq_scan_rare_value") { |top| top.merge!("Node Type" => "CTE Scan", "CTE Name" => "w") }
      b = changed("seq_scan_rare_value") { |top| top.merge!("Node Type" => "CTE Scan", "CTE Name" => "v") }
      expect(canonical(a).matches?(canonical(b))).to be(false)
      a = changed("seq_scan_rare_value") { |top| top.merge!("Node Type" => "Function Scan", "Function Name" => "f") }
      b = changed("seq_scan_rare_value") { |top| top.merge!("Node Type" => "Function Scan", "Function Name" => "g") }
      expect(canonical(a).matches?(canonical(b))).to be(false)
    end

    it "tells a plan with one more node apart" do
      differs("sort_under_limit") { |top| top["Plans"].first["Plans"] = [] }
    end

    it "tells plans with a different number of statements apart" do
      expect(canonical(plan("hash_aggregate")).matches?(canonical(plan("hash_aggregate") * 2))).to be(false)
    end

    ["Filter", "Index Cond", "Recheck Cond", "Join Filter", "Hash Cond", "Merge Cond", "TID Cond",
     "One-Time Filter", "Run Condition", "Order By"].each do |key|
      it "tells a #{key} on another column apart" do
        a = changed("seq_scan_rare_value") { |top| top[key] = "(total_cents < 5000)" }
        b = changed("seq_scan_rare_value") { |top| top[key] = "(customer_id < 5000)" }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end

      it "tells a #{key} with another operator apart" do
        a = changed("seq_scan_rare_value") { |top| top[key] = "(total_cents < 5000)" }
        b = changed("seq_scan_rare_value") { |top| top[key] = "(total_cents > 5000)" }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end

      it "tells a plan with a #{key} from one without it" do
        differs("hash_aggregate") { |top| top[key] = "(total_cents < 5000)" }
      end
    end

    it "tells a Filter with one more conjunct apart" do
      differs("seq_scan_rare_value") { |top| top["Filter"] = "((status = 'failed'::text) AND (id > 100))" }
    end

    ["Sort Key", "Presorted Key", "Group Key"].each do |key|
      it "tells a #{key} on another column apart" do
        a = changed("incremental_sort") { |top| top["Plans"].first[key] = %w[status total_cents] }
        b = changed("incremental_sort") { |top| top["Plans"].first[key] = %w[status customer_id] }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end

      it "tells a #{key} in another direction apart" do
        a = changed("incremental_sort") { |top| top["Plans"].first[key] = %w[status total_cents] }
        b = changed("incremental_sort") { |top| top["Plans"].first[key] = ["status", "total_cents DESC"] }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end

      it "tells a #{key} with other nulls ordering apart" do
        a = changed("incremental_sort") { |top| top["Plans"].first[key] = ["total_cents DESC"] }
        b = changed("incremental_sort") { |top| top["Plans"].first[key] = ["total_cents DESC NULLS LAST"] }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end

      it "tells a #{key} with its keys in another order apart" do
        a = changed("incremental_sort") { |top| top["Plans"].first[key] = %w[status total_cents] }
        b = changed("incremental_sort") { |top| top["Plans"].first[key] = %w[total_cents status] }
        expect(canonical(a).matches?(canonical(b))).to be(false)
      end
    end
  end
end
