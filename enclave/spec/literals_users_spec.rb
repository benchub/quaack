# frozen_string_literal: true

require "prism"
require "tmpdir"
require "quaack/enclave/steps/literals"

# Task 20261010-7: literals refuses to run again once a step has stored an
# entry that compares numbers by literal set name (Literals::USERS), since
# new sets would make those numbers compare across different values. This
# spec reads every step that loads the sets (directly, through
# Measurement, or through IndexShare) and checks that each entry it writes
# either matches USERS or is listed here as one that compares nothing
# across sets. A new step that loads the sets and writes an entry fails
# here until someone decides which it is.
#
# Task 20261110-18: the scan follows the store wherever a step passes it
# (a local alias, or a positional argument to a method in the same file),
# reads names built with if, case, or ||, and fails on a step that loads
# the sets but has no write the scan can read, unless writes_elsewhere
# names what it writes through another module.
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
    /\Arewrites_generated\z/ => "a flag",
    /\Aindex_build\z/ => "index-build runs after index-search, whose index_search_ entries USERS already covers"
  }
  # Steps whose store.write names aren't string literals, with why.
  dynamic = { "rewrite_check.rb" => "save writes rewrite_N, a rewrite's SQL, compared by nothing" }
  # Steps that load the sets but write through another module, with the
  # names that module writes.
  writes_elsewhere = { "index_build.rb" => ["index_build"] }

  # The names a write's first argument can be: nil for one that isn't a
  # string or a choice between strings. An interpolation stands in as "1".
  names = lambda do |arg|
    case arg
    when Prism::StringNode then [arg.unescaped]
    when Prism::InterpolatedStringNode then [arg.parts.map { it.is_a?(Prism::StringNode) ? it.unescaped : "1" }.join]
    when Prism::ParenthesesNode, Prism::StatementsNode
      body = arg.is_a?(Prism::ParenthesesNode) ? arg.body : arg
      body.is_a?(Prism::StatementsNode) ? names.call(body.body.last) : names.call(body)
    when Prism::IfNode, Prism::UnlessNode
      other = arg.is_a?(Prism::IfNode) ? arg.subsequent : arg.else_clause
      [arg.statements, other&.statements].flat_map { it ? names.call(it) : [nil] }
    when Prism::ElseNode then arg.statements ? names.call(arg.statements) : [nil]
    when Prism::CaseNode
      branches = arg.conditions.map(&:statements) + [arg.else_clause&.statements]
      branches.flat_map { it ? names.call(it) : [nil] }
    when Prism::OrNode then names.call(arg.left) + names.call(arg.right)
    else [nil]
    end
  end

  all_nodes = lambda do |node, &block|
    block.call(node)
    node.compact_child_nodes.each { all_nodes.call(it, &block) }
  end

  # The local names that hold the store in a file: store, anything assigned
  # from one of them, and any positional parameter of a method in the same
  # file that's called with one of them in that position.
  store_names = lambda do |tree|
    defs = []
    all_nodes.call(tree) { defs << it if it.is_a?(Prism::DefNode) }
    held = Set["store"]
    loop do
      before = held.size
      all_nodes.call(tree) do |node|
        if node.is_a?(Prism::LocalVariableWriteNode) && node.value.is_a?(Prism::LocalVariableReadNode) &&
           held.include?(node.value.name.to_s)
          held << node.name.to_s
        elsif node.is_a?(Prism::CallNode) && node.arguments
          node.arguments.arguments.each_with_index do |arg, i|
            next unless arg.is_a?(Prism::LocalVariableReadNode) && held.include?(arg.name.to_s)

            defs.select { it.name == node.name }.each do |d|
              param = d.parameters&.requireds&.[](i)
              held << param.name.to_s if param.respond_to?(:name)
            end
          end
        end
      end
      break if held.size == before
    end
    held
  end

  # [description, failure message or nil] for every check the scan makes
  # on the step files at paths.
  scan = lambda do |paths|
    paths.select { File.read(it).match?(loads_sets) }.flat_map do |path|
      file = File.basename(path)
      tree = Prism.parse_file(path).value
      held = store_names.call(tree)
      found = []
      all_nodes.call(tree) do |node|
        next unless node.is_a?(Prism::CallNode) && node.name == :write && held.include?(node.receiver&.slice)

        line = node.location.start_line
        names.call(node.arguments&.arguments&.first).uniq.each { found << [line, it] }
      end
      elsewhere = writes_elsewhere.fetch(file, []).map { [nil, it] }
      if found.empty? && elsewhere.empty?
        next [["finds a write in #{file}",
               "#{file} loads the literal sets but the scan found no store write in it: " \
               "if it writes through another module, list the names in writes_elsewhere"]]
      end

      (found + elsewhere).map do |line, name|
        where = line ? "#{file}:#{line}" : "#{file} (through another module)"
        if name
          listed = name.match?(described_class::USERS) || not_compared.keys.any? { name.match?(it) }
          ["lists #{where}'s #{name} in USERS or as compared by nothing across sets",
           if listed
             nil
           else
             "#{where} loads the literal sets and writes #{name}: add it to USERS, " \
               "or to this spec's not_compared with why"
           end]
        else
          ["has a reason for #{where}'s write whose name isn't a string",
           if dynamic.key?(file)
             nil
           else
             "#{where} writes a name the scan can't read (not a string, " \
               "or a choice between strings): list #{file} in dynamic with why"
           end]
        end
      end
    end
  end

  real = scan.call(Dir[File.join(steps_dir, "*.rb")])

  it "finds the steps USERS names, so the scan reads what it should" do
    descriptions = real.map(&:first).join("\n")
    %w[baseline index_baseline candidate_runs result_comparison index_search_1].each do |name|
      expect(descriptions).to match(/'s #{name} in USERS/)
    end
  end

  it "gives every check its own description" do
    descriptions = real.map(&:first)
    expect(descriptions).to eq(descriptions.uniq)
  end

  real.each do |description, failure|
    it(description) { expect(failure).to be_nil, failure }
  end

  describe "on planted steps" do
    plant = lambda do |source|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "planted_step.rb")
        File.write(path, source)
        scan.call([path]).filter_map(&:last)
      end
    end

    it "follows a store passed to a helper under another name" do
      failures = plant.call(<<~RUBY)
        def call(store:, **)
          LiteralSet.load(store)
          save(store, 1)
        end

        def save(st, n) = st.write("planted_entry", n)
      RUBY
      expect(failures).to contain_exactly(
        a_string_including("planted_step.rb:6 loads the literal sets and writes planted_entry")
      )
    end

    it "follows a store assigned to a local" do
      failures = plant.call(<<~RUBY)
        def call(store:, **)
          s = store
          Measurement.measure(s)
          s.write("planted_entry", 1)
        end
      RUBY
      expect(failures).to contain_exactly(a_string_including("writes planted_entry"))
    end

    it "reads each name a case or || chooses" do
      failures = plant.call(<<~RUBY)
        def call(store:, kind:, **)
          LiteralSet.load(store)
          store.write(case kind when 1 then "planted_a" else "baseline" end, 1)
          store.write(kind || "planted_b", 1)
        end
      RUBY
      expect(failures).to contain_exactly(
        a_string_including("writes planted_a"),
        a_string_including("writes a name the scan can't read"),
        a_string_including("writes planted_b")
      )
    end

    it "fails on a step that loads the sets but has no write it can read" do
      failures = plant.call(<<~RUBY)
        def call(store:, **)
          IndexShare.combinations(store)
          Other.save(store)
        end
      RUBY
      expect(failures).to contain_exactly(
        a_string_including("planted_step.rb loads the literal sets but the scan found no store write")
      )
    end

    it "gives two writes of one name on different lines their own descriptions" do
      descriptions = Dir.mktmpdir do |dir|
        path = File.join(dir, "planted_step.rb")
        File.write(path, <<~RUBY)
          def call(store:, **)
            LiteralSet.load(store)
            store.write("baseline", 1)
            store.write("baseline", 2)
          end
        RUBY
        scan.call([path]).map(&:first)
      end
      expect(descriptions.size).to eq(2)
      expect(descriptions).to eq(descriptions.uniq)
    end

    it "passes a planted step whose writes are all listed" do
      failures = plant.call(<<~RUBY)
        def call(store:, **)
          LiteralSet.load(store)
          store.write("baseline", 1)
        end
      RUBY
      expect(failures).to be_empty
    end
  end
end
