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

    def rewrites(parse, catalog)
      change.call(PgQuery.deparse(parse.tree), catalog).map do |sql|
        Quaack::Enclave::RewriteRules::Rewrite.new(tree: PgQuery.parse(sql).tree, assumptions: [assumption].compact)
      end
    end
  end

  let(:original) { PgQuery.parse("SELECT 1") }
  let(:catalog) { Object.new }

  define_method(:rule) do |name, assumption = nil, &change|
    fake_rule.new(name:, assumption:, change: ->(sql, _catalog) { Array(change.call(sql)) })
  end

  def appending(name, assumption = nil) = rule(name, assumption) { "#{it}, '#{name}'" }
  def generate(*rules) = described_class.generate(original, catalog, rules:)
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

    expect(names(generated)).to eq([%w[a], %w[b], %w[a a], %w[a b], %w[b a]])
    expect(sqls(generated).last).to eq("SELECT 1, 'b', 'a'")
  end

  it "keeps at most five, and counts the rest as over the cap" do
    generated = generate(appending("a"), appending("b"))

    expect([generated.rewrites.size, generated.over_cap, generated.duplicates]).to eq([5, 1, 0])
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

  it "hands every rule the catalog facts" do
    seen = []
    spy = fake_rule.new(name: "spy", assumption: nil, change: ->(_sql, given) { (seen << given) && [] })

    generate(spy)

    expect(seen).to eq([catalog])
  end

  it "lists QUAACK's rules, each with a name, a description, and the rewrites method" do
    expect(described_class::RULES.map(&:name)).to eq(%w[key_in_self_join])
    expect(described_class::RULES).to all(respond_to(:rewrites) & have_attributes(description: a_kind_of(String)))
  end
end
