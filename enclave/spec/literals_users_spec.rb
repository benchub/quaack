# frozen_string_literal: true

require "prism"
require "quaack/enclave/steps/literals"

# Task 20261010-7: literals refuses to run again once a step has stored an
# entry that compares numbers by literal set name (Literals::USERS), since
# new sets would make those numbers compare across different values. This
# spec reads every step that loads the sets (directly, through
# Measurement, or through IndexShare) and checks that each entry it writes
# either matches USERS or is listed here as one that compares nothing
# across sets. A new step that loads the sets and writes an entry fails
# here until someone decides which it is.
RSpec.describe Quaack::Enclave::Steps::Literals do
  steps_dir = File.expand_path("../lib/quaack/enclave/steps", __dir__)
  loads_sets = /\b(LiteralSet\.load|Measurement\.measure|IndexShare\.)/

  # Entries written by steps that load the sets but store nothing compared
  # by set name, each with why.
  not_compared = {
    /\Aindex_ranking_.+\z/ => "index-rank stores one ranking it makes in one process",
    /\Aindex_llm_ranked_.+\z/ => "a flag",
    /\Aindex_generated_.+\z/ => "a flag",
    /\Arewrite_pruned_.+\z/ => "plan-pruning stores which rewrites it discarded",
    /\Aown_rewrites\z/ => "rewrite-check stores the operator's rewrites' outcomes",
    /\Aoperator_rewrites_checked\z/ => "a flag",
    /\Arewrites_generated\z/ => "a flag"
  }
  # Steps whose store.write names aren't string literals, with why.
  dynamic = { "rewrite_check.rb" => "save writes rewrite_N, a rewrite's SQL, compared by nothing" }

  # The names a store.write's first argument can be: nil for one that
  # isn't a string or a choice between strings. An interpolation stands
  # in as "1".
  names = lambda do |arg|
    case arg
    when Prism::StringNode then [arg.unescaped]
    when Prism::InterpolatedStringNode then [arg.parts.map { it.is_a?(Prism::StringNode) ? it.unescaped : "1" }.join]
    when Prism::IfNode then [arg.statements.body.first, arg.subsequent.statements.body.first].flat_map(&names)
    else [nil]
    end
  end

  # [file, name or nil] for every store.write in a step that loads the sets.
  writes = Dir[File.join(steps_dir, "*.rb")].select { File.read(it).match?(loads_sets) }.flat_map do |path|
    found = []
    visit = lambda do |node|
      if node.is_a?(Prism::CallNode) && node.name == :write && node.receiver&.slice == "store"
        arg = node.arguments&.arguments&.first
        names.call(arg).each { found << [File.basename(path), it] }
      end
      node.compact_child_nodes.each(&visit)
    end
    visit.call(Prism.parse_file(path).value)
    found.uniq
  end

  it "finds the steps USERS names, so the scan reads what it should" do
    names = writes.map(&:last)
    expect(names).to include("baseline", "index_baseline", "candidate_runs", "result_comparison", "index_search_1")
  end

  writes.each do |file, name|
    if name
      it "lists #{file}'s #{name} in USERS or as compared by nothing across sets" do
        listed = name.match?(described_class::USERS) || not_compared.keys.any? { name.match?(it) }
        expect(listed).to be(true), "#{file} loads the literal sets and writes #{name}: add it to USERS, " \
                                    "or to this spec's not_compared with why"
      end
    else
      it "has a reason for #{file}'s store.write whose name isn't a string" do
        expect(dynamic).to have_key(file)
      end
    end
  end
end
