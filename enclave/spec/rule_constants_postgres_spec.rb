# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/redaction"
require "quaack/enclave/rewrite_rules"
require "quaack/enclave/rewrite_rules/catalog"
require "quaack/enclave/steps/rewrite_payload"

# Task 20261006-14. rewrite-payload sends a rule's rewrite in rule_rewrites
# only if every constant it holds is in the redacted query or in
# RewritePayload::RULE_CONSTANTS. A rule that wrote any other constant, such
# as a 0 or a NULL, would have its rewrites dropped without a word. So every
# rule in RULES runs here over its fixture, and every rewrite it takes part
# in must hold only those constants. A new rule fails here until it has a
# fixture it fires on, and until RULE_CONSTANTS holds what it writes.
#
# A rule's fixture is its docs/transforms page's schema (its first SQL
# block) and "Before" query, with LITERALS in place of the query's $n, in
# order. The query is redacted as intake redacts it, and the rules get the
# literal oracle, as in a real run.
module RuleConstantsFixtures
  LITERALS = {
    "implied_predicate_removal" => ["'active'", "'deleted'", "'rejected'", "42"],
    "transitive_predicate_copy" => %w[1 2 3],
    "shared_scan_cte" => ["'active'", "'active'"],
    "key_in_self_join" => ["'registered'", "42"],
    "or_to_union" => %w[42 7],
    "not_in_to_not_exists" => %w[42],
    "existence_in_flip" => ["1", "'registered'", "42", "1"],
    "distinct_join_to_exists" => %w[42],
    "cte_hoist_dedupe" => ["'available'", "'available'"],
    "union_outer_filter_removal" => %w[5 5 5],
    "unused_join_removal" => %w[5],
    "polymorphic_key_copy" => ["'Course'", "42"]
  }.freeze

  # The rule's fixture: its schema and its query with literals in place of
  # the placeholders. nil if it has no page, no schema or Before, or no
  # LITERALS entry.
  def self.for(name)
    path = File.join(REPO_ROOT, "docs/transforms/#{name}.md")
    return unless File.exist?(path) && LITERALS.key?(name)

    page = File.read(path)
    schema = page[/```sql\n(.*?)```/m, 1]
    before = page[/^Before:\n\n```sql\n(.*?)```/m, 1]
    return unless schema && before

    { schema:, query: before.gsub(/\$(\d+)/) { LITERALS.fetch(name).fetch(Regexp.last_match(1).to_i - 1) } }
  end
end

RSpec.describe "Rule constants" do
  rules = Quaack::Enclave::RewriteRules::RULES
  payload = Quaack::Enclave::Steps::RewritePayload

  def fixture(name) = RuleConstantsFixtures.for(name)

  it "has a fixture for every rule in RULES" do
    expect(rules.map(&:name).reject { fixture(it) }).to eq([])
  end

  rules.each do |rule|
    it "writes only the query's constants and RULE_CONSTANTS in #{rule.name}'s rewrites" do
      fixture = fixture(rule.name)
      expect(fixture).not_to be_nil, "#{rule.name} has no fixture"

      conn = TestPostgres.server.create_database("template0").connection
      conn.exec(fixture[:schema])
      redacted = Quaack::Enclave::Redaction.query(PgQuery.parse(fixture[:query]))
      literals = Quaack::Enclave::RewriteRules::Literals.new(conn, redacted.placeholder_map)
      catalog = Quaack::Enclave::RewriteRules::Catalog.new(conn)
      generated = Quaack::Enclave::RewriteRules.generate(PgQuery.parse(redacted.sql), catalog, literals)
      mine = generated.rewrites.select { it.rules.include?(rule) }
      expect(mine).not_to be_empty, "#{rule.name} doesn't fire on its fixture"

      allowed = payload.constants(redacted.sql) | payload.constants(payload::RULE_CONSTANTS)
      mine.each do |rewrite|
        extra = (payload.constants(rewrite.sql) - allowed).map { PgQuery::A_Const.decode(it).to_h }
        expect(extra).to eq([]), "#{rule.name} wrote #{extra}, outside RULE_CONSTANTS, in #{rewrite.sql}"
      end
    end
  end
end
