# frozen_string_literal: true

require "json"
require "quaack/driver/winner_summary"
require "quaack/protocol/step_counts"
require_relative "support/fake_llm"
require_relative "support/routers"

# The winner summary explains why the winner wins, as a heuristic a
# developer can reuse (20261010-28): what changed in the query's structure,
# why that let the planner do less work, and the pattern to look for. The
# LLM is faked at the client's edge. Every query, plan, and name here is
# synthetic.
# Synthetic fixtures for the spec below.
module WinnerSummaryWhy # rubocop:disable Metrics/ModuleLength
  # Each family: its payload, an answer in the shape the prompt asks for
  # that names only node types its plans have, and one that names a node
  # type neither plan has.
  FAMILIES = {
    "or_to_union" => {
      rule: "or_to_union",
      original: "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id " \
                "WHERE o.state = $1 OR u.region = $2",
      winner: "SELECT id FROM (SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id " \
              "WHERE o.state = $1 UNION SELECT o.id FROM public.orders o JOIN public.users u " \
              "ON u.id = o.user_id WHERE u.region = $2) s",
      original_plan: %i[hash_join seq_orders seq_users],
      winner_plan: %i[unique append index_orders index_users],
      good: "The original query put conditions on two different tables inside one OR, and Rewrite Quiet Heron " \
            "split it into a UNION with one arm per condition. Each arm filters a single table, so the planner " \
            "could use an Index Scan in each arm where the original ran a Seq Scan on public.orders under a " \
            "Hash Join. The winner read 40 blocks on the slow values against 9,000. Look for an OR whose arms " \
            "test columns of different tables.",
      bad: "Rewrite Quiet Heron split the OR, so the planner could use a Bitmap Heap Scan. It read 40 blocks."
    },
    "not_in_to_not_exists" => {
      rule: "not_in_to_not_exists",
      original: "SELECT id FROM public.users WHERE id NOT IN (SELECT user_id FROM public.bans)",
      winner: "SELECT id FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.bans b WHERE b.user_id = u.id)",
      original_plan: %i[seq_users_subplan seq_bans],
      winner_plan: %i[hash_join_anti seq_users seq_bans_hash],
      good: "Rewrite Quiet Heron turned the NOT IN subquery into a NOT EXISTS correlated on user_id. Because " \
            "both columns are not null, the planner could run it as a Hash Join instead of rescanning " \
            "public.bans for each row of the Seq Scan on public.users. The winner read 300 blocks against " \
            "9,000. Look for NOT IN over columns that can't be null.",
      bad: "Rewrite Quiet Heron used NOT EXISTS, so the planner chose a Merge Join. It read 300 blocks."
    },
    "existence_in_flip" => {
      rule: "existence_in_flip",
      original: "SELECT 1 FROM public.orders WHERE user_id IN (SELECT id FROM public.users WHERE region = $1) " \
                "LIMIT 1",
      winner: "SELECT 1 FROM public.users u WHERE u.region = $1 AND EXISTS (SELECT 1 FROM public.orders o " \
              "WHERE o.user_id = u.id) LIMIT 1",
      original_plan: %i[limit seq_orders],
      winner_plan: %i[limit nested_loop index_users index_orders],
      good: "The original query checked for any order whose user is in a region by scanning orders first. " \
            "Rewrite Quiet Heron made the users in the region drive, with an EXISTS on their orders, so the " \
            "planner could stop at the first match with a Nested Loop over two Index Scan steps instead of a " \
            "Seq Scan on public.orders. The winner read 40 blocks against 9,000. Look for an existence check " \
            "under LIMIT 1 whose IN list is small.",
      bad: "Rewrite Quiet Heron flipped the check, so a Memoize step helped. It read 40 blocks."
    },
    "shared_scan_cte" => {
      rule: "shared_scan_cte",
      original: "SELECT a.id FROM public.orders a JOIN public.orders b ON b.parent_id = a.id " \
                "WHERE a.state = $1 AND b.state = $1",
      winner: "WITH s AS MATERIALIZED (SELECT * FROM public.orders WHERE state = $1) " \
              "SELECT a.id FROM s a JOIN s b ON b.parent_id = a.id",
      original_plan: %i[hash_join seq_orders seq_orders],
      winner_plan: %i[hash_join cte_scan cte_scan seq_orders],
      good: "The original query read public.orders twice with the same state filter. Rewrite Quiet Heron read " \
            "it once into a materialized CTE that both sides join, so the plan has one Seq Scan on " \
            "public.orders feeding two CTE Scan steps instead of two Seq Scan steps. The winner read 4,500 " \
            "blocks against 9,000. Look for a table joined to itself with the same filter on both copies.",
      bad: "Rewrite Quiet Heron read the table once, so an Index Only Scan did the rest. It read 4,500 blocks."
    },
    "union_outer_filter_removal" => {
      rule: "union_outer_filter_removal",
      original: "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
                "SELECT id, state FROM public.archived WHERE state = $1) s WHERE s.state = $1",
      winner: "SELECT id FROM (SELECT id, state FROM public.orders WHERE state = $1 UNION " \
              "SELECT id, state FROM public.archived WHERE state = $1) s",
      original_plan: %i[subquery_scan unique append seq_orders],
      winner_plan: %i[subquery_scan unique append index_orders],
      good: "The original query filtered the UNION's output on state, which every arm already filters. Rewrite " \
            "Quiet Heron removed the outer filter, and the winner's plan reads public.orders with an Index Scan " \
            "where the original ran a Seq Scan. The winner read 40 blocks against 9,000. Look for a filter " \
            "outside a UNION that each arm already applies.",
      bad: "Rewrite Quiet Heron removed the filter, so a Gather step ran it in parallel. It read 40 blocks."
    },
    "key_in_self_join" => {
      rule: "key_in_self_join",
      original: "SELECT id FROM public.orders WHERE id IN (SELECT o2.id FROM public.orders o2 WHERE o2.state = $1)",
      winner: "SELECT id FROM public.orders WHERE state = $1",
      original_plan: %i[hash_join seq_orders seq_orders],
      winner_plan: [:index_orders],
      good: "The original query read public.orders again in an IN subquery keyed on its own id. Rewrite Quiet " \
            "Heron moved the subquery's filter onto the outer table, so the planner could drop the Hash Join " \
            "and read the table once with an Index Scan. The winner read 40 blocks against 9,000. Look for an " \
            "IN subquery that selects the outer table's own key from the same table.",
      bad: "Rewrite Quiet Heron removed the self-join, leaving a Bitmap Index Scan. It read 40 blocks."
    },
    "an index-only win" => {
      rule: nil, index: "CREATE INDEX ON public.orders USING btree (state, id)",
      original: "SELECT id FROM public.orders WHERE state = $1",
      winner: nil,
      original_plan: [:seq_orders],
      winner_plan: [:index_only_orders],
      good: "The query is unchanged, and the winner adds an index on state and id. Because the index holds " \
            "every column the query reads, the planner could answer it with an Index Only Scan instead of a " \
            "Seq Scan on public.orders. The winner read 12 blocks against 9,000. Look for a query that filters " \
            "on one column and selects only a few others.",
      bad: "The new index let the planner use an Index Scan. It read 12 blocks against 9,000."
    }
  }.freeze

  NODES = {
    hash_join: ["Hash Join", nil, nil, 9_000], hash_join_anti: ["Hash Join", nil, nil, 300],
    nested_loop: ["Nested Loop", nil, nil, 40], limit: ["Limit", nil, nil, nil], unique: ["Unique", nil, nil, nil],
    append: ["Append", nil, nil, nil], subquery_scan: ["Subquery Scan", nil, nil, nil],
    seq_orders: ["Seq Scan", "public.orders", nil, 9_000], seq_users: ["Seq Scan", "public.users", nil, 100],
    seq_users_subplan: ["Seq Scan", "public.users", nil, 9_000], seq_bans: ["Seq Scan", "public.bans", nil, 50],
    seq_bans_hash: ["Seq Scan", "public.bans", nil, 50], cte_scan: ["CTE Scan", nil, nil, 4_500],
    index_orders: ["Index Scan", "public.orders", "orders_state_idx", 40],
    index_users: ["Index Scan", "public.users", "users_region_idx", 10],
    index_only_orders: ["Index Only Scan", "public.orders", "quaack_1", 12]
  }.freeze

  WINNER_TOTALS = { "not_in_to_not_exists" => 300, "shared_scan_cte" => 4_500, "an index-only win" => 12 }.freeze
end

RSpec.describe Quaack::Driver::WinnerSummary do
  include Routers

  families = WinnerSummaryWhy::FAMILIES

  def node(type, table = nil, index = nil, counts = {})
    rows, blocks, depth = counts.values_at(:rows, :blocks, :depth)
    { "node" => type, "relation" => table, "index" => index, "est_rows" => rows, "actual_rows" => rows,
      "selectivity" => nil, "depth" => depth || 0, "shared_hit_blocks" => blocks, "shared_read_blocks" => 0 }
  end

  def m(blocks) = { "total_blocks" => blocks, "hit" => blocks, "read" => 0, "stable" => true, "timed_out" => false }

  # A report payload whose winner is a rule-made rewrite (or, with rule nil,
  # the original query with a new index).
  def payload(family, original_plan, winner_plan)
    rule, original, winner, index = family.values_at(:rule, :original, :winner, :index)
    label = rule ? "rewrite_1:top:1" : "original:top:1"
    { "top" => [{ "label" => label }], "original_sql" => original,
      "original_measurements" => { "slow" => m(original_plan.first["shared_hit_blocks"]) },
      "original_plan" => original_plan,
      "labels" => [{ "label" => label, "indexes" => index ? ["quaack_1"] : [], "plan" => winner_plan,
                     "measurements" => { "slow" => m(winner_plan.first["shared_hit_blocks"]) } }],
      "rewrites" => [{ "rewrite" => "rewrite_1", "name" => "Quiet Heron", "source" => "rule",
                       "rules" => [rule], "sql" => winner, "plan" => winner_plan }].select { rule },
      "indexes" => index ? { "quaack_1" => { "ddl" => index } } : {} }
  end

  # A plan's nodes, the first holding the plan's total blocks.
  def plan_of(keys, total)
    keys.each_with_index.map do |key, depth|
      type, table, index, blocks = WinnerSummaryWhy::NODES.fetch(key)
      node(type, table, index, rows: 10, blocks: depth.zero? ? total : (blocks || 0), depth:)
    end
  end

  def family_payload(name)
    family = WinnerSummaryWhy::FAMILIES.fetch(name)
    payload(family,
            plan_of(family[:original_plan], 9_000),
            plan_of(family[:winner_plan], WinnerSummaryWhy::WINNER_TOTALS.fetch(name, 40)))
  end

  let(:fake) { FakeLLM.new }

  def run(answer, payload)
    fake.reply("winner-summary", answer)
    described_class.new(client: router_of(fake)).run(payload)
  end

  families.each do |name, family|
    describe "a #{name} winner" do
      it "keeps an answer that explains the change and names only node types the plans have" do
        expect(run(family[:good], family_payload(name))).to have_attributes(text: family[:good], outcome: "used")
      end

      it "refuses an answer that names a node type neither plan has" do
        expect(run(family[:bad], family_payload(name))).to have_attributes(text: nil, outcome: "rejected")
      end
    end
  end

  describe "the node-type check" do
    let(:base) { family_payload("key_in_self_join") }

    it "reads a node type in any case, and a sequential scan as a Seq Scan" do
      expect(run("The winner drops the hash join and reads 40 blocks.", base)).to have_attributes(outcome: "used")
      expect(run("The winner drops a bitmap heap scan and reads 40 blocks.", base))
        .to have_attributes(outcome: "rejected")
      expect(run("The original ran a sequential scan on public.orders.", base)).to have_attributes(outcome: "used")
      without_seq = base.merge("original_plan" => plan_of([:hash_join], 9_000))
      expect(run("The original ran a sequential scan on public.orders.", without_seq))
        .to have_attributes(outcome: "rejected")
    end

    it "takes the longest node type, so an Index Only Scan isn't read as an Index Scan" do
      payload = family_payload("an index-only win")
      expect(run("The winner uses an index-only scan and reads 12 blocks.", payload))
        .to have_attributes(outcome: "used")
      expect(run("The winner uses a Bitmap Index Scan and reads 12 blocks.", payload))
        .to have_attributes(outcome: "rejected")
      expect(run("The winner uses an index-only scan and reads 40 blocks.", base))
        .to have_attributes(outcome: "rejected")
      gathered = base.merge("original_plan" => [node("Gather Merge", nil, nil, rows: 10, blocks: 9_000)])
      expect(run("The original ran a Gather Merge over 9,000 blocks.", gathered)).to have_attributes(outcome: "used")
    end

    it "doesn't read the SQL keywords LIMIT, UNIQUE, or a plain word such as sort as a node type" do
      text = "The original query has LIMIT 1 and a UNIQUE key, and the winner needs no sort of extra work."
      expect(run(text, base)).to have_attributes(outcome: "used")
      expect(run("The winner needs no Sort and reads 40 blocks.", base)).to have_attributes(outcome: "rejected")
    end
  end

  describe "the input" do
    it "gives each of the rewrite's rules its fixed one-line purpose, and none for a name QUAACK doesn't know" do
      payload = family_payload("or_to_union")
      payload["rewrites"][0]["rules"] = %w[or_to_union not_a_rule]
      rewrite = described_class::Input.build(payload).dig("winner", "rewrite")

      expect(rewrite["rule_purposes"]).to eq("or_to_union" => described_class::Input::RULE_PURPOSES["or_to_union"])
      expect(rewrite["rule_purposes"]["or_to_union"]).to include("OR").and include("UNION")
    end

    it "has a purpose for every one of QUAACK's rules" do
      expect(described_class::Input::RULE_PURPOSES.keys).to match_array(Quaack::Protocol::StepCounts::RULE_NAMES)
    end
  end

  describe "the prompt" do
    let(:system) do
      run(WinnerSummaryWhy::FAMILIES["or_to_union"][:good], family_payload("or_to_union"))
      fake.asks.fetch(0).body[:system]
    end

    it "asks what changed in the query's structure, why that let the planner do less work, and the pattern" do
      expect(system).to include("what changed in the query's structure")
        .and include("why that change let the planner do less work")
        .and include("the pattern a developer could look for in their own queries")
        .and include("rule_purposes")
    end

    it "allows a causal claim only when a plan difference in the payload backs it, and keeps the old bans" do
      expect(system).to include("only when a difference between the two plans in the payload backs it")
        .and include("caching, table bloat, statistics, or data distribution")
        .and include("never carry one step's row count to another step")
        .and include("Don't mention any other rewrite or index")
        .and include("No markdown")
        .and include("under 700 characters")
      expect(system).not_to include("Describe a plan step only by its node type")
    end

    it "quotes no example of what to write" do
      expect(system).not_to match(/["“”]/)
    end
  end
end
