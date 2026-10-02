# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/burndown"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/steps/rewrite_rules"
require_relative "support/index_search_run"

# `quaacks rewrite-rules` (DESIGN.md 6c), the way the jump server runs it: the
# rules' rewrites go through rewrite-check's checks, the survivors are stored
# as rewrite-check stores them, and only rewrite_outcome fields go out.
RSpec.describe "quaacks rewrite-rules, against a real server" do
  include_context "an index search run"

  # orders.id is its primary key, so key_in_self_join fires. The slow
  # literal in the subquery is a sentinel.
  let(:query) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.id IN " \
      "(SELECT o2.id FROM public.orders o2 WHERE o2.note = '#{sentinels.text}') AND o.status = 'held'"
  end
  let(:plain_query) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held'"
  end
  let(:rewritten) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2" }
  let(:key_assumptions) do
    [{ "kind" => "unique", "table" => "public.orders", "columns" => ["id"] },
     { "kind" => "not_null", "table" => "public.orders", "column" => "id" }]
  end

  def rewrite_rules = quaacks.run("rewrite-rules", "--run", store.run_id, env: libpq_env)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }
  def status = JSON.parse(quaacks.run("status", "--run", store.run_id).stdout.lines.first)

  def outcome_line(index, outcome, rule = nil, rewrite = nil)
    { "type" => "rewrite_outcome", "index" => index, "outcome" => outcome, "rule" => rule, "rewrite" => rewrite,
      "warnings" => [] }
  end

  it "stores a rule's rewrite as rewrite-check stores one, with its source and rule names" do
    prepare
    expect(store.read("redacted_query")).to include("$1").and include("o2.id")

    outcome = rewrite_rules

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    rule = Quaack::Enclave::RewriteRules::RULES.first
    expect(stored.read("rewrite_1")).to eq(
      "sql" => rewritten, "transformation" => rule.description, "assumptions" => key_assumptions,
      "inferred" => false, "warnings" => [], "result_types" => %w[text text], "anchored_sql" => rewritten,
      "source" => "rule", "rules" => ["key_in_self_join"]
    )
    expect(stored.entry?("rewrite_2")).to be(false)
  end

  it "sends only one rewrite_outcome per rewrite, and nothing of the literals" do
    prepare
    expect(stored.read("literal_sets").to_s).to include(sentinels.text)

    outcome = rewrite_rules

    expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"), { "type" => "done" }])
    expect_no_leaks(sentinels, outcome)
  end

  it "writes the rewrite_rules_applied marker, which status reports" do
    prepare
    expect(status["entries"]).to include("rewrite_rules_applied" => false)

    rewrite_rules

    expect(status["entries"]).to include("rewrite_rules_applied" => true, "rewrite_1" => true,
                                         "rewrites_generated" => false, "operator_rewrites_checked" => false)
    expect(stored.read("rewrite_rules_applied")).to eq("duplicates" => 0, "over_cap" => 0)
  end

  it "adds its rewrites to the step 8 burndown, as rewrite-check does" do
    prepare

    rewrite_rules

    expect(Quaack::Enclave::Burndown.read(stored)["stages"]["step8"]["rewrites"])
      .to include("in" => 1, "out" => 1, "dropped" => { "inbound_check" => 0, "failed_to_plan" => 0,
                                                        "output_mismatch" => 0 })
  end

  context "when no rule fires" do
    let(:query) { plain_query }

    it "sends nothing but done, stores no rewrite, and still writes the marker" do
      prepare

      outcome = rewrite_rules

      expect([lines(outcome), outcome.status.exitstatus]).to eq([[{ "type" => "done" }], 0])
      expect(stored.entry?("rewrite_1")).to be(false)
      expect(stored.entry?("rewrite_rules_applied")).to be(true)
    end
  end

  context "with rules given to the step in place of its own" do
    let(:query) { plain_query }
    let(:fake_rule) do
      Data.define(:name, :sql, :assumptions) do
        def description = "the fake rule #{name}"

        def rewrites(parse, _catalog)
          return [] unless parse.query.include?("o.note = $1 AND o.status = $2")

          [Quaack::Enclave::RewriteRules::Rewrite.new(tree: PgQuery.parse(sql).tree, assumptions:)]
        end
      end
    end
    let(:not_null_note) { { "kind" => "not_null", "table" => "public.orders", "column" => "note" } }
    let(:rules) do
      select = "SELECT o.note, o.status FROM public.orders o WHERE"
      [fake_rule.new(name: "bad_placeholder", sql: "#{select} o.note = $3", assumptions: []),
       fake_rule.new(name: "unmet", sql: "#{select} o.note = $1 AND true", assumptions: [not_null_note]),
       fake_rule.new(name: "bad_assumption", sql: "#{select} o.note = $1 AND 1 = 1", assumptions: [{ "kind" => "x" }]),
       fake_rule.new(name: "mismatch", sql: "SELECT o.note FROM public.orders o WHERE o.note = $1", assumptions: []),
       fake_rule.new(name: "sound", sql: "#{select} o.note = $1", assumptions: [])]
    end

    def call_step(rules) = with_env(libpq_env) { Quaack::Enclave::Steps::RewriteRules.call(store:, rules:) }

    it "puts each rewrite through the inbound check, 6b, and the structural discards, by rewrite-check's rules" do
      prepare

      outcomes = call_step(rules)

      expect(outcomes.map { it.values_at(:index, :outcome, :rule, :rewrite) }).to eq(
        [[1, :rejected, "bad_placeholder", nil], [2, :rejected, "unmet_assumption", nil],
         [3, :rejected, "bad_assumption", nil], [4, :rejected, "output_mismatch", nil],
         [5, :accepted, nil, "rewrite_1"]]
      )
      expect(stored.read("rewrite_1").slice("sql", "transformation", "source", "rules")).to eq(
        "sql" => "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1",
        "transformation" => "the fake rule sound", "source" => "rule", "rules" => ["sound"]
      )
      expect(Quaack::Enclave::Burndown.read(stored)["stages"]["step8"]["rewrites"])
        .to include("in" => 3, "out" => 1, "dropped" => { "inbound_check" => 1, "failed_to_plan" => 0,
                                                          "output_mismatch" => 1 })
    end

    it "stores a chained rewrite with every rule's name and description, in order, and counts what it dropped" do
      prepare
      first = fake_rule.new(name: "first", sql: "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2",
                            assumptions: [])
      second = Data.define(:name) do
        def description = "the fake rule #{name}"

        def rewrites(parse, _catalog)
          return [] unless parse.query.end_with?("WHERE o.status = $2")

          tree = PgQuery.parse("#{parse.query} AND o.note = $1").tree
          [Quaack::Enclave::RewriteRules::Rewrite.new(tree:, assumptions: [])]
        end
      end.new(name: "second")

      outcomes = call_step([first, second, first])

      expect(outcomes.map { it[:rewrite] }).to eq(%w[rewrite_1 rewrite_2])
      expect(stored.read("rewrite_2").slice("sql", "transformation", "rules")).to eq(
        "sql" => "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1",
        "transformation" => "the fake rule first the fake rule second", "rules" => %w[first second]
      )
      expect(stored.read("rewrite_rules_applied")).to eq("duplicates" => 1, "over_cap" => 0)
    end
  end

  it "numbers 6a's rewrites after the rules', and says which source each came from" do
    prepare
    rewrite_rules
    llm = { "rewrites" => [{ "sql" => rewritten, "transformation" => "t", "assumptions" => [] }] }

    quaacks.run("rewrite-check", "--run", store.run_id, stdin: JSON.generate(llm), env: libpq_env)
    quaacks.run("rewrite-check", "--run", store.run_id, stdin: JSON.generate(llm.merge("inferred" => true)),
                                                        env: libpq_env)

    expect((1..3).map { stored.read("rewrite_#{it}").slice("source", "rules") })
      .to eq([{ "source" => "rule", "rules" => ["key_in_self_join"] }, { "source" => "llm" },
              { "source" => "operator" }])
  end
end
