# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/burndown"
require "quaack/enclave/egress"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/steps/rewrite_rules"
require_relative "support/index_search_run"

# `quaacks rewrite-rules` (DESIGN.md's rewrite-rules), the way the jump server runs it: the
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

  def rules_line(names) = { "type" => "step_counts", "rules" => names }

  # The step's messages but its step_counts.
  def outcomes_of(messages) = messages.select { it[:type] == :rewrite_outcome }

  # The rule names its step_counts message carries.
  def fired(messages) = messages.find { it[:type] == :step_counts }.fetch(:rules)

  it "stores a rule's rewrite as rewrite-check stores one, with its source and rule names" do
    prepare
    expect(store.read("redacted_query")).to include("$1").and include("o2.id")

    outcome = rewrite_rules

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    rule = Quaack::Enclave::RewriteRules::RULES.find { it.name == "key_in_self_join" }
    expect(stored.read("rewrite_1")).to eq(
      "sql" => rewritten, "transformation" => rule.description, "assumptions" => key_assumptions,
      "inferred" => false, "warnings" => [], "result_types" => %w[text text], "anchored_sql" => rewritten,
      "source" => "rule", "rules" => ["key_in_self_join"]
    )
    expect(stored.entry?("rewrite_2")).to be(false)
  end

  it "sends only one rewrite_outcome per rewrite and the rules that fired, and nothing of the literals" do
    prepare
    expect(stored.read("literal_sets").to_s).to include(sentinels.text)

    outcome = rewrite_rules

    expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"), rules_line(["key_in_self_join"]),
                                  { "type" => "done" }])
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

  it "records rewrite-rules and assumption-check, so the stage that follows starts where rewrite-rules ended" do
    prepare

    rewrite_rules

    expect(Quaack::Enclave::Burndown.read(stored)["stages"].keys).to eq(%w[rewrite-rules assumption-check])
    expect(burndown("assumption-check")).to include("in" => 1, "out" => 1, "dropped" => { "unmet_assumption" => 0 })
  end

  def burndown(stage) = Quaack::Enclave::Burndown.read(stored)["stages"].dig(stage, "rewrites")

  def six_c(added, out, **dropped)
    { "in" => 0, "added" => added, "set_aside" => 0, "out" => out, "extra" => {},
      "dropped" => { "duplicate" => 0, "over_cap" => 0, "failed_checks" => 0 }.merge(dropped.transform_keys(&:to_s)) }
  end

  it "records the rewrite-rules burndown: its rewrites, counted by the last rule applied" do
    prepare

    rewrite_rules

    expect(burndown("rewrite-rules")).to eq(six_c({ "key_in_self_join" => 1 }, 1))
  end

  # A crash between storing the rewrites and writing the marker leaves a run
  # the driver sends here again (DESIGN.md's rewrite-rules). Each example puts the store
  # in the state such a crash leaves.
  describe "run again after a call that died before writing its marker" do
    def remove(entry) = FileUtils.rm_f(File.join(stored.path, "#{entry}.json"))

    def rerun
      outcome = rewrite_rules
      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      outcome
    end

    it "stores no rewrite twice, and counts none twice, when it died after recording its burndown" do
      prepare
      rewrite_rules
      first = [stored.read("rewrite_1"), Quaack::Enclave::Burndown.read(stored)]
      remove("rewrite_rules_applied")

      outcome = rerun

      expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"), rules_line(["key_in_self_join"]),
                                    { "type" => "done" }])
      expect(stored.entry?("rewrite_2")).to be(false)
      expect([stored.read("rewrite_1"), Quaack::Enclave::Burndown.read(stored)]).to eq(first)
      expect(status["entries"]).to include("rewrite_rules_applied" => true)
    end

    it "stores no rewrite twice, and records its burndown once, when it died before recording it" do
      prepare
      expect(stored.entry?("burndown")).to be(false)
      rewrite_rules
      first = Quaack::Enclave::Burndown.read(stored)
      expect(first["stages"].keys).to eq(%w[rewrite-rules assumption-check])
      remove("rewrite_rules_applied")
      remove("burndown")

      rerun

      expect(stored.entry?("rewrite_2")).to be(false)
      expect(Quaack::Enclave::Burndown.read(stored)).to eq(first)
    end

    it "is the same when it's run again with its marker written" do
      prepare
      rewrite_rules
      first = Quaack::Enclave::Burndown.read(stored)

      rerun

      expect(stored.entry?("rewrite_2")).to be(false)
      expect(Quaack::Enclave::Burndown.read(stored)).to eq(first)
    end

    it "still stores llm-rewrites' copy of a rule's rewrite as a rewrite of its own" do
      prepare
      rewrite_rules
      llm = { "rewrites" => [{ "sql" => rewritten, "transformation" => "t", "assumptions" => [] }] }

      quaacks.run("rewrite-check", "--run", store.run_id, stdin: JSON.generate(llm), env: libpq_env)

      expect(stored.read("rewrite_2")).to include("sql" => rewritten, "source" => "llm")
    end

    it "still stores a rule's rewrite when only llm-rewrites' copy of it is stored" do
      prepare
      llm = { "rewrites" => [{ "sql" => rewritten, "transformation" => "t", "assumptions" => [] }] }
      quaacks.run("rewrite-check", "--run", store.run_id, stdin: JSON.generate(llm), env: libpq_env)

      outcome = rerun

      expect(lines(outcome).first).to eq(outcome_line(1, "accepted", nil, "rewrite_2"))
      expect((1..2).map { stored.read("rewrite_#{it}").values_at("sql", "source") })
        .to eq([[rewritten, "llm"], [rewritten, "rule"]])
    end
  end

  context "when no rule fires" do
    let(:query) { plain_query }

    it "sends no outcome and no rule, stores no rewrite, and still writes the marker" do
      prepare

      outcome = rewrite_rules

      expect([lines(outcome), outcome.status.exitstatus]).to eq([[rules_line([]), { "type" => "done" }], 0])
      expect(stored.entry?("rewrite_1")).to be(false)
      expect(stored.entry?("rewrite_rules_applied")).to be(true)
      expect(burndown("rewrite-rules")).to eq(six_c({}, 0))
    end
  end

  context "with rules given to the step in place of its own" do
    let(:query) { plain_query }
    let(:fake_rule) do
      Data.define(:name, :sql, :assumptions) do
        def description = "the fake rule #{name}"

        def rewrites(parse, _catalog, _literals)
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

    it "puts each rewrite through inbound-check, assumption-check, and structural-discard, as rewrite-check says" do
      prepare

      outcomes = outcomes_of(call_step(rules))

      expect(outcomes.map { it.values_at(:index, :outcome, :rule, :rewrite) }).to eq(
        [[1, :rejected, "bad_placeholder", nil], [2, :rejected, "unmet_assumption", nil],
         [3, :rejected, "bad_assumption", nil], [4, :rejected, "output_mismatch", nil],
         [5, :accepted, nil, "rewrite_1"]]
      )
      expect(stored.read("rewrite_1").slice("sql", "transformation", "source", "rules")).to eq(
        "sql" => "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1",
        "transformation" => "the fake rule sound", "source" => "rule", "rules" => ["sound"]
      )
      # rewrite-rules ends with what got past arrival, and the stages after it take it from there.
      expect(burndown("rewrite-rules")).to eq(six_c(rules.to_h { [it.name, 1] }, 3, failed_checks: 2))
      expect(burndown("assumption-check")).to include("in" => 3, "out" => 2, "dropped" => { "unmet_assumption" => 1 })
      expect(burndown("plan-pruning")).to include("in" => 1, "out" => 0, "dropped" => { "output_mismatch" => 1 })
    end

    # Run again after a call that died before its marker (DESIGN.md's rewrite-rules), with two
    # rule rewrites, both stored or only the first.
    describe "run again with two rule rewrites" do
      let(:two) do
        select = "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1"
        [fake_rule.new(name: "one", sql: select, assumptions: []),
         fake_rule.new(name: "two", sql: "#{select} AND 2 = 2", assumptions: [])]
      end

      def remove(entry) = FileUtils.rm_f(File.join(stored.path, "#{entry}.json"))

      def first_call
        prepare
        call_step(two)
        remove("rewrite_rules_applied")
        [stored.read("rewrite_1"), stored.read("rewrite_2"), Quaack::Enclave::Burndown.read(stored)]
      end

      it "stores neither again when both were stored" do
        first = first_call

        expect(outcomes_of(call_step(two)).map { it[:rewrite] }).to eq(%w[rewrite_1 rewrite_2])
        expect(stored.entry?("rewrite_3")).to be(false)
        expect([stored.read("rewrite_1"), stored.read("rewrite_2"), Quaack::Enclave::Burndown.read(stored)])
          .to eq(first)
      end

      it "stores only the missing one when the call stored only the first" do
        first = first_call
        remove("rewrite_2")

        expect(outcomes_of(call_step(two)).map { it[:rewrite] }).to eq(%w[rewrite_1 rewrite_2])
        expect(stored.entry?("rewrite_3")).to be(false)
        expect([stored.read("rewrite_1"), stored.read("rewrite_2"), Quaack::Enclave::Burndown.read(stored)])
          .to eq(first)
      end
    end

    it "stores a chained rewrite with every rule's name and description, in order, and counts what it dropped" do
      prepare
      first = fake_rule.new(name: "first", sql: "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2",
                            assumptions: [])
      second = Data.define(:name) do
        def description = "the fake rule #{name}"

        def rewrites(parse, _catalog, _literals)
          return [] unless parse.query.end_with?("WHERE o.status = $2")

          tree = PgQuery.parse("#{parse.query} AND o.note = $1").tree
          [Quaack::Enclave::RewriteRules::Rewrite.new(tree:, assumptions: [])]
        end
      end.new(name: "second")

      outcomes = outcomes_of(call_step([first, second, first]))

      expect(outcomes.map { it[:rewrite] }).to eq(%w[rewrite_1 rewrite_2])
      expect(stored.read("rewrite_2").slice("sql", "transformation", "rules")).to eq(
        "sql" => "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1",
        "transformation" => "the fake rule first the fake rule second", "rules" => %w[first second]
      )
      expect(stored.read("rewrite_rules_applied")).to eq("duplicates" => 1, "over_cap" => 0)
      expect(burndown("rewrite-rules")).to eq(six_c({ "first" => 2, "second" => 1 }, 2, duplicate: 1))
    end

    # Task 20261004-1: a rule's name goes out only if it's on the protocol's
    # shared list, so a name that isn't, such as a planted sentinel, never does.
    it "names only the fired rules on the shared list, in its order, and never a planted name" do
      prepare
      select = "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1"
      planted = fake_rule.new(name: sentinels.word, sql: "#{select} AND 1 = 1", assumptions: [])
      known = %w[or_to_union key_in_self_join].map.with_index(2) do |name, n|
        fake_rule.new(name:, sql: "#{select} AND #{n} = #{n}", assumptions: [])
      end
      silent = Data.define(:name) do
        def description = "never fires"
        def rewrites(*) = []
      end.new(name: "shared_scan_cte")

      messages = call_step([planted, *known, silent])

      expect(outcomes_of(messages).size).to eq(3)
      expect(fired(messages)).to eq(%w[key_in_self_join or_to_union])
      expect_no_leaks(sentinels, stdout: JSON.generate(messages.map { Quaack::Enclave::Egress.serialize(it) }))
    end

    it "names every rule a chained rewrite applied, not only its first" do
      prepare
      first = fake_rule.new(name: "or_to_union", assumptions: [],
                            sql: "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2")
      second = Data.define(:name) do
        def description = "the fake rule #{name}"

        def rewrites(parse, _catalog, _literals)
          return [] unless parse.query.end_with?("WHERE o.status = $2")

          [Quaack::Enclave::RewriteRules::Rewrite.new(tree: PgQuery.parse("#{parse.query} AND o.note = $1").tree,
                                                      assumptions: [])]
        end
      end.new(name: "key_in_self_join")

      messages = call_step([first, second])

      expect(stored.read("rewrite_2")["rules"]).to eq(%w[or_to_union key_in_self_join])
      expect(fired(messages)).to eq(%w[key_in_self_join or_to_union])
    end

    it "counts the rewrites over the cap in the marker and the rewrite-rules burndown" do
      prepare
      select = "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1"
      eleven = (1..11).map { fake_rule.new(name: "rule#{it}", sql: "#{select} AND #{it} = #{it}", assumptions: []) }
      duplicates = [fake_rule.new(name: "duplicate_rule2", sql: "#{select} AND 2 = 2", assumptions: []),
                    fake_rule.new(name: "duplicate_rule7", sql: "#{select} AND 7 = 7", assumptions: [])]

      outcomes = outcomes_of(call_step([*eleven, *duplicates]))

      expect(outcomes.map { it[:rewrite] }).to eq((1..10).map { "rewrite_#{it}" })
      expect(stored.read("rewrite_1").slice("sql", "transformation", "rules")).to eq(
        "sql" => "#{select} AND 1 = 1", "transformation" => "the fake rule rule1", "rules" => ["rule1"]
      )
      expect(stored.read("rewrite_10").slice("sql", "transformation", "rules")).to eq(
        "sql" => "#{select} AND 10 = 10", "transformation" => "the fake rule rule10", "rules" => ["rule10"]
      )
      expect(stored.entry?("rewrite_11")).to be(false)
      expect(stored.read("rewrite_rules_applied")).to eq("duplicates" => 2, "over_cap" => 1)
      expect(burndown("rewrite-rules"))
        .to eq(six_c((1..11).to_h { ["rule#{it}", 1] }.merge("duplicate_rule2" => 1, "duplicate_rule7" => 1),
                     10, duplicate: 2, over_cap: 1))
    end
  end

  it "numbers llm-rewrites' rewrites after the rules', and says which source each came from" do
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

  context "when implied_predicate_removal uses sentinel literals" do
    let(:query) do
      "SELECT o.note, o.status FROM public.orders o WHERE o.note <> 'ordinary' AND " \
        "o.note = '#{sentinels.text}' AND o.status = 'held'"
    end
    let(:rewritten) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $2 AND o.status = $3" }

    it "stores only the redacted rewrite and never sends the sentinel value out" do
      prepare
      expect(stored.read("placeholder_map").to_s).to include(sentinels.text)

      outcome = rewrite_rules

      expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"),
                                    rules_line(["implied_predicate_removal"]), { "type" => "done" }])
      expect(stored.read("rewrite_1")).to include(
        "sql" => rewritten, "source" => "rule", "rules" => ["implied_predicate_removal"]
      )
      expect_no_leaks(sentinels, outcome)
      expect_no_leaks(sentinels, objects: { rewrite: stored.read("rewrite_1"),
                                            burndown: Quaack::Enclave::Burndown.read(stored) })
    end
  end

  # Task 20261002-4: distinct_join_to_exists through the step. orders.id is
  # its primary key, so a DISTINCT over the self-join that holds it becomes
  # one read with an EXISTS.
  context "when distinct_join_to_exists fires" do
    let(:query) do
      "SELECT DISTINCT o.id, o.note FROM public.orders o JOIN public.orders o2 ON o2.total = o.total " \
        "WHERE o2.note = '#{sentinels.text}'"
    end
    let(:rewritten) do
      "SELECT o.id, o.note FROM public.orders o WHERE EXISTS (SELECT 1 FROM public.orders o2 " \
        "WHERE o2.total = o.total AND o2.note = $1)"
    end

    it "stores the rule's rewrite with its key assumptions, and never sends the sentinel out" do
      prepare

      outcome = rewrite_rules

      expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"),
                                    rules_line(["distinct_join_to_exists"]), { "type" => "done" }])
      expect(stored.read("rewrite_1")).to include(
        "sql" => rewritten, "assumptions" => key_assumptions, "source" => "rule", "rules" => ["distinct_join_to_exists"]
      )
      expect_no_leaks(sentinels, outcome)
    end
  end

  # Task 20261001-28: DESIGN.md's llm-rewrites. rewrite-payload sends the rule-made
  # rewrites' SQL and rule names, so the LLM doesn't repeat them.
  describe "rewrite-payload's rule_rewrites" do
    def rewrite_payload
      store.write("schema_subset", "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id int);\n")
      outcome = quaacks.run("rewrite-payload", "--run", store.run_id)
      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      outcome
    end

    def rule_rewrites(outcome) = JSON.parse(outcome.stdout.lines.first)["rule_rewrites"]

    it "sends each rule-made rewrite's SQL and rule names, and nothing of the literals" do
      prepare
      rewrite_rules

      outcome = rewrite_payload

      expect(rule_rewrites(outcome)).to eq([{ "sql" => rewritten, "rules" => ["key_in_self_join"] }])
      expect_no_leaks(sentinels, outcome)
    end

    it "sends no other source's rewrite, no unknown rule name, and never assumptions or a transformation" do
      prepare
      rewrite_rules
      entry = stored.read("rewrite_1")
      stored.write("rewrite_1", entry.merge("rules" => ["key_in_self_join", sentinels.text],
                                            "transformation" => sentinels.text,
                                            "assumptions" => [{ "kind" => "denormalized_equal",
                                                                "type_value" => sentinels.text }]))
      stored.write("rewrite_2", entry.merge("source" => "llm", "sql" => "#{rewritten} AND true"))

      outcome = rewrite_payload

      expect(rule_rewrites(outcome)).to eq([{ "sql" => rewritten, "rules" => ["key_in_self_join"] }])
      expect_no_leaks(sentinels, outcome)
    end

    # The check itself works: a rule-made rewrite whose SQL holds a constant
    # the redacted query doesn't, and no rule writes, is never sent.
    it "never sends a rule-made rewrite whose SQL holds a planted literal" do
      prepare
      rewrite_rules
      entry = stored.read("rewrite_1")
      stored.write("rewrite_1", entry.merge("sql" => rewritten.sub("$1", "'#{sentinels.text}'")))
      stored.write("rewrite_2", entry.merge("sql" => rewritten.sub("$1", "42")))
      stored.write("rewrite_3", entry.merge("sql" => "#{rewritten} AND EXISTS (SELECT 1) AND true"))

      outcome = rewrite_payload

      expect(rule_rewrites(outcome)).to eq([{ "sql" => "#{rewritten} AND EXISTS (SELECT 1) AND true",
                                              "rules" => ["key_in_self_join"] }])
      expect_no_leaks(sentinels, outcome)
    end
  end
end
