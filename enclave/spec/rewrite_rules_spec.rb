# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/rewrite_rules"

# DESIGN.md 6c's generator: it holds a list of rules and chains them, and
# knows nothing about any one rule. These rules are fakes, given through the
# generator's own list interface.
RSpec.describe Quaack::Enclave::RewriteRules do
  # A rule that maps the query's SQL to the SQL of zero or more rewrites.
  fake_rule = Data.define(:name, :assumption, :change) do
    def description = "the fake rule #{name}"

    def rewrites(parse, catalog, literals)
      change.call(PgQuery.deparse(parse.tree), catalog, literals).map do |sql|
        Quaack::Enclave::RewriteRules::Rewrite.new(tree: PgQuery.parse(sql).tree, assumptions: [assumption].compact)
      end
    end
  end

  let(:original) { PgQuery.parse("SELECT 1") }
  let(:catalog) { Object.new }
  let(:literals) { Object.new }

  define_method(:rule) do |name, assumption = nil, &change|
    fake_rule.new(name:, assumption:, change: ->(sql, _catalog, _literals) { Array(change.call(sql)) })
  end

  def appending(name, assumption = nil) = rule(name, assumption) { "#{it}, '#{name}'" }
  def one_shot(name, sql_name = name) = rule(name) { |sql| sql == "SELECT 1" ? "#{sql}, '#{sql_name}'" : [] }
  def generate(*rules) = described_class.generate(original, catalog, literals, rules:)
  def sqls(generated) = generated.rewrites.map(&:sql)
  def names(generated) = generated.rewrites.map { |rewrite| rewrite.rules.map(&:name) }

  it "runs each rule on the original, in list order, and gives each result's SQL, rules, and assumptions" do
    generated = generate(appending("a", { "kind" => "a" }), rule("none") { [] }, appending("b"))

    expect(generated.rewrites.first(2).map { [it.sql, it.rules.map(&:name), it.assumptions] })
      .to eq([["SELECT 1, 'a'", ["a"], [{ "kind" => "a" }]], ["SELECT 1, 'b'", ["b"], []]])
  end

  it "gives a result its deparsed SQL's own parse" do
    rewrite = generate(appending("a")).rewrites.first

    expect(rewrite.parse.tree).to eq(PgQuery.parse("SELECT 1, 'a'").tree)
  end

  it "chains breadth first: every one-rule result comes before any two-rule result, each in list order" do
    generated = described_class.generate(original, catalog, rules: [appending("a"), appending("b")])

    expect(names(generated)).to eq([%w[a], %w[b], %w[a a], %w[a b], %w[b a], %w[b b]])
    expect(sqls(generated).last).to eq("SELECT 1, 'b', 'b'")
  end

  it "keeps at most ten, and counts the rest as over the cap" do
    generated = generate(*(1..11).map { one_shot("rule#{it}") },
                         one_shot("duplicate_rule2", "rule2"), one_shot("duplicate_rule7", "rule7"))

    expect([generated.rewrites.size, generated.over_cap, generated.duplicates]).to eq([10, 1, 2])
    expect(names(generated)).to eq((1..10).map { ["rule#{it}"] })
    expect([sqls(generated).first, sqls(generated).last]).to eq(["SELECT 1, 'rule1'", "SELECT 1, 'rule10'"])
    expect(generated.made).to include("rule11" => 1, "duplicate_rule2" => 1, "duplicate_rule7" => 1)
  end

  it "goes at most two rules deep" do
    generated = generate(appending("a"))

    expect(sqls(generated)).to eq(["SELECT 1, 'a'", "SELECT 1, 'a', 'a'"])
  end

  it "gathers a chained result's assumptions from both rules, each once" do
    same = { "kind" => "not_null", "table" => "public.t", "column" => "id" }
    other = same.merge("column" => "k")

    generated = generate(appending("a", same), rule("b", other) { "#{it} + 1" })

    expect(generated.rewrites.to_h { [it.rules.map(&:name), it.assumptions] })
      .to include(%w[a a] => [same], %w[a b] => [same, other], %w[b a] => [other, same])
  end

  it "drops a result whose deparsed SQL was already produced, and counts it" do
    generated = generate(rule("two") { "SELECT 2" }, rule("also_two") { "select  2 /* again */" })

    expect([sqls(generated), names(generated), generated.duplicates]).to eq([["SELECT 2"], [%w[two]], 3])
  end

  it "drops a result that is the original again" do
    generated = generate(rule("same") { it })

    expect([generated.rewrites, generated.duplicates]).to eq([[], 1])
  end

  it "drops a result pg_query can't deparse faithfully, and keeps the others" do
    generated = generate(rule("unfaithful") { ["SELECT 't'::boolean", "SELECT 3"] })

    expect(sqls(generated)).to eq(["SELECT 3"])
  end

  describe "made, for the 6c burndown" do
    it "counts every result by the last rule applied, those kept and those over the cap" do
      # a, b, a a, a b, and b a are kept, and b b is over the cap.
      expect(generate(appending("a"), appending("b")).made).to eq("a" => 3, "b" => 3)
    end

    it "counts a chained result under its last rule, not its first" do
      after_a = rule("b") { it.include?("'a'") ? "#{it}, 'b'" : [] }
      generated = generate(appending("a"), after_a)

      expect([names(generated), generated.made]).to eq([[%w[a], %w[a a], %w[a b]], { "a" => 2, "b" => 1 }])
    end

    it "counts a duplicate under the rule that made it" do
      generated = generate(rule("two") { "SELECT 2" }, rule("also_two") { "select  2 /* again */" })

      expect(generated.made).to eq("two" => 2, "also_two" => 2)
      expect(generated.made.values.sum).to eq(generated.rewrites.size + generated.duplicates + generated.over_cap)
    end

    it "leaves out a result pg_query can't deparse faithfully, and a rule that made nothing" do
      generated = generate(rule("unfaithful") { ["SELECT 't'::boolean", "SELECT 3"] }, rule("none") { [] })

      expect([generated.made, generated.duplicates]).to eq([{ "unfaithful" => 2 }, 1])
    end
  end

  it "hands every rule the catalog facts" do
    seen = []
    spy = fake_rule.new(name: "spy", assumption: nil, change: ->(_sql, given, _literals) { (seen << given) && [] })

    generate(spy)

    expect(seen).to eq([catalog])
  end

  it "hands every rule the literals oracle" do
    seen = []
    spy = fake_rule.new(name: "spy", assumption: nil, change: ->(_sql, _catalog, given) { (seen << given) && [] })

    generate(spy)

    expect(seen).to eq([literals])
  end

  it "lists QUAACK's rules, each with a name, a description, and the rewrites method" do
    expect(described_class::RULES.map(&:name))
      .to eq(%w[implied_predicate_removal transitive_predicate_copy shared_scan_cte key_in_self_join or_to_union
                not_in_to_not_exists existence_in_flip distinct_join_to_exists cte_hoist_dedupe
                union_outer_filter_removal polymorphic_key_copy])
    expect(described_class::RULES).to all(respond_to(:rewrites) & have_attributes(description: a_kind_of(String)))
  end
end
