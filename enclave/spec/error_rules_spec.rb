# frozen_string_literal: true

require "quaack/protocol"
require_relative "support/error_rule_scan"

# Task 20261007-29: Protocol::ErrorRules lists every rule the enclave's
# error line can carry, so the driver can give each one words without
# loading the enclave. ErrorRuleScan finds the rules the source writes at
# its raise sites; the rules it can't see are read here from where they're
# built.
RSpec.describe Quaack::Protocol::ErrorRules do
  root = File.join(GEM_ROOT, "lib")
  enclave = File.join(root, "quaack", "enclave")

  # Literals the scan meets at a rule site that aren't rules: hash keys and
  # method names read beside one, and ShellCommand's suffixes, which become
  # rules only with a prefix (see the ShellCommand example below).
  not_rules = %w[cause rule refusal sqlstate failed timed_out bad_output].freeze

  # Rules that never reach an error line: each is a verdict, a stored
  # outcome, or an error its own step rescues and records.
  never_sent = {
    "discarded" => "rewrite-test's stored result for a pruned rewrite (steps/counterexamples.rb)",
    "subset_timed_out" => "a ProductionComparison verdict",
    "hypopg_refused" => "a SingleCandidateTest refusal, stored in the candidate's result",
    "unrenderable" => "a SingleCandidateTest refusal, stored in the candidate's result",
    "too_many" => "rewrite-check's Rejected, rescued into the rewrite's outcome",
    "bad_assumption" => "rewrite-check's Rejected, rescued into the rewrite's outcome",
    "unmet_assumption" => "rewrite-check's Rejected, rescued into the rewrite's outcome"
  }.freeze

  # Every file with a raise site the scan can't read a rule from, and
  # where its rules come from. A new one fails until it's listed here.
  dynamic = {
    "arena_runner.rb" => "a caller's rule: keyword, or ArenaRunner::Cancel.rule's",
    "arena_runner/transaction_status.rb" => "its rule and refusal locals, and its callers' rule: keywords",
    "index_ddl_check.rb" => "REFUSED_OPTIONS, read below",
    "index_methods.rb" => "IndexCandidateError, whose rule is fixed",
    "insert_check.rb" => "REFUSED_FORMS, read below",
    "insert_values.rb" => "an InsertCheck::Error's rule, raised again",
    "intake/operator_file.rb" => "<kind>_too_large and <kind>_unreadable, read below",
    "redaction/binding.rb" => "guarded's callers",
    "relation_qualifier.rb" => "a message for an Error whose rule is fixed",
    "relations.rb" => "its rule locals, and KINDS and OTHER, read below",
    "result_comparison/load_orders.rb" => "LOAD_FAILED, read below",
    "run_server_check.rb" => "fail!'s callers",
    "scenarios/values.rb" => "its rule local",
    "single_candidate_test.rb" => "guarded's and hypopg's callers",
    "single_candidate_test/hypopg.rb" => "hypopg's callers",
    "steps/counterexamples.rb" => "<prefix>_unknown_search and <prefix>_no_arena_setup, read below",
    "steps/rewrite_check.rb" => "StructuralDiscard's reasons, rescued into the rewrite's outcome",
    "store.rb" => "a message for Store::BadBase, whose rule is fixed",
    "supported_sql.rb" => "a node type for an Error whose rule is fixed",
    "user_schema.rb" => "a message for an Error whose rule is fixed"
  }.freeze

  let(:scan) { ErrorRuleScan.scan(root) }
  let(:names) { described_class::NAMES }

  before(:all) do
    Dir.glob("**/*.rb", base: root).sort.each { require File.join(root, it) }
  end

  it "names only rules shaped as ErrorFilter sends them, each once" do
    expect(names.grep_v(Quaack::Enclave::ErrorFilter::RULE)).to eq([])
    expect(names.uniq).to eq(names)
  end

  it "holds every rule the source writes at a raise site" do
    found = scan.rules.keys - not_rules - never_sent.keys

    expect(found - names).to eq([])
  end

  it "lists every file whose raise sites the scan can't read" do
    files = scan.dynamic.map { it.delete_prefix("quaack/enclave/").sub(/:\d+\z/, "") }.uniq.sort

    expect(files).to eq(dynamic.keys.sort)
  end

  it "holds ErrorFilter's own rule for an error with none" do
    expect(names).to include(Quaack::Enclave::ErrorFilter::INTERNAL_ERROR)
  end

  it "holds every rule a constant table raises by variable" do
    tables = [*Quaack::Enclave::ArenaRunner::RULES.keys, *Quaack::Enclave::ResultComparison::RULES.keys,
              *Quaack::Enclave::ResultComparison::LOAD_FAILED.values,
              *Quaack::Enclave::InsertCheck::REFUSED_FORMS.map(&:first),
              *Quaack::Enclave::IndexDdlCheck::RULES,
              *Quaack::Enclave::Relations::KINDS.values.map(&:first), Quaack::Enclave::Relations::OTHER.first]

    expect(tables.map(&:to_s) - names).to eq([])
  end

  it "holds every rule ShellCommand builds from a caller's prefix" do
    prefixes = %w[run_server_command.rb inventory/memory.rb].flat_map do |file|
      ErrorRuleScan.call_literals(enclave, file, :run_command, keyword: :prefix) +
        ErrorRuleScan.call_literals(enclave, file, :output, keyword: :prefix)
    end
    suffixes = ErrorRuleScan.call_literals(enclave, "shell_command.rb", :fail!, position: 0)
    built = prefixes.uniq.product(suffixes.uniq).map { |prefix, suffix| "#{prefix}_#{suffix}" }

    expect(prefixes.uniq.sort).to eq(%w[destroy_command memory_command run_server_command])
    expect(suffixes.uniq.sort).to eq(%w[bad_output failed timed_out])
    expect(built - names).to eq([])
  end

  it "holds every rule intake builds from an operator file's kind" do
    kinds = ErrorRuleScan.call_literals(enclave, "intake.rb", :read, position: 1)
    built = kinds.product(%w[too_large unreadable]).map { |kind, suffix| "#{kind}_#{suffix}" }

    expect(kinds.sort).to eq(%w[plan query])
    expect(built - names).to eq([])
  end

  it "holds every rule the counterexample steps build from a step's prefix" do
    built = { search!: "unknown_search", arena!: "no_arena_setup" }.flat_map do |call, suffix|
      prefixes = ErrorRuleScan.call_literals(enclave, "steps/counterexamples.rb", call, position: -1)
      expect(prefixes).not_to be_empty
      prefixes.map { "#{it}_#{suffix}" }
    end

    expect(built - names).to eq([])
  end

  it "knows Store::MissingEntry's rule for any entry, as its own family" do
    rule = Quaack::Enclave::Store::MissingEntry.new("no entry", entry: "index_search_rewrite_3").rule

    expect(rule).to eq("missing_index_search_rewrite_3")
    expect(described_class.known?(rule)).to be(true)
    expect(names).not_to include(rule)
  end

  it "knows no rule it doesn't list" do
    expect(described_class.known?("no_such_rule")).to be(false)
    expect(described_class.known?("missing_")).to be(false)
  end

  it "lists no rule that nothing in the enclave raises" do
    shell = %w[destroy_command memory_command run_server_command].product(%w[bad_output failed timed_out])
                                                                 .map { it.join("_") }
    built = [*scan.rules.keys, *shell, "query_too_large", "plan_too_large", "query_unreadable", "plan_unreadable",
             "rewrite_test_unknown_search", "rewrite_test_no_arena_setup", "counterexample_payload_unknown_search",
             "counterexample_round_unknown_search", "counterexample_round_no_arena_setup",
             *Quaack::Enclave::ArenaRunner::RULES.keys.map(&:to_s),
             *Quaack::Enclave::ResultComparison::RULES.keys.map(&:to_s),
             *Quaack::Enclave::InsertCheck::REFUSED_FORMS.map(&:first), *Quaack::Enclave::IndexDdlCheck::RULES,
             *Quaack::Enclave::Relations::KINDS.values.map(&:first), Quaack::Enclave::Relations::OTHER.first,
             Quaack::Enclave::ErrorFilter::INTERNAL_ERROR]

    expect(names - built).to eq([])
  end
end
