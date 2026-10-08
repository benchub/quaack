# frozen_string_literal: true

require "prism"

# Finds the rule names the enclave's source writes where it raises
# (task 20261007-29), so a spec can check Protocol::ErrorRules holds them
# all.
#
#   scan = ErrorRuleScan.scan(root)
#   scan.rules   # => { "bad_port" => ["quaack/enclave/intake.rb:44"], ... }
#   scan.dynamic # => ["quaack/enclave/insert_check.rb:162", ...]
#
# A rule is any Symbol or String literal shaped like ErrorFilter::RULE
# found at one of these sites:
#
# - raise X, rule and raise(X, rule), for any constant X.
# - X.new(rule, ...) for a constant X whose name ends in Error, Refused,
#   or Refusal.
# - the argument of a call in RULE_CALLS, each a helper that takes a rule
#   and raises with it, such as RunServerCheck#fail!.
# - a rule: keyword argument.
# - anywhere in the body of a method named rule, such as
#   ArenaRunner::Cancel.rule.
# - anywhere in the value written to @rule, or to a local named rule or
#   refusal, such as a ternary between two rules.
#
# At the first three, every literal in the argument counts, so a ternary
# between two rules gives both. A constant the same file assigns a plain
# String, such as NameQualifier::RegLiteral's UNSUPPORTED, counts as that
# String. An argument with no literal at all, such as a variable or an
# interpolation, is a dynamic site: the scan can't tell its rule, so the
# spec lists every one and says where its rules come from.
module ErrorRuleScan
  RULE = /\A[a-z][a-z0-9_]{0,62}\z/
  # The helpers that take a rule, by the argument position it's at, and
  # raise an error with it.
  RULE_CALLS = { fail!: 0, guarded: 0, hypopg: 0, database: 0 }.freeze
  ERROR_CLASS = /(Error|Refused|Refusal)\z/
  RULE_LOCALS = %i[rule refusal].freeze
  STANDARD = %w[ArgumentError TypeError KeyError RangeError IndexError RuntimeError NotImplementedError
                FrozenError StandardError].freeze

  Result = Data.define(:rules, :dynamic)

  module_function

  def scan(root)
    rules = Hash.new { |hash, key| hash[key] = [] }
    dynamic = []
    Dir.glob("**/*.rb", base: root).sort.each do |path|
      tree = Prism.parse_file(File.join(root, path)).value
      constants = constants(tree)
      each_node(tree) do |node|
        where = "#{path}:#{node.location.start_line}"
        found, open = sites(node, constants)
        found.select { it.match?(RULE) }.each { rules[it] << where }
        dynamic << where if open
      end
    end
    Result.new(rules:, dynamic:)
  end

  # The String literals passed to the calls named name in the file at path,
  # under root, as the argument at position or the keyword keyword, such
  # as the prefixes ShellCommand builds rules from.
  def call_literals(root, path, name, position: nil, keyword: nil)
    found = []
    each_node(Prism.parse_file(File.join(root, path)).value) do |node|
      next unless node.is_a?(Prism::CallNode) && node.name == name

      args = node.arguments&.arguments || []
      arg = position ? args[position] : keyword_value(args, keyword)
      found << arg.unescaped if arg.is_a?(Prism::StringNode)
    end
    found
  end

  def keyword_value(args, keyword)
    hash = args.last
    return unless hash.is_a?(Prism::KeywordHashNode)

    hash.elements.find { it.key.is_a?(Prism::SymbolNode) && it.key.unescaped == keyword.to_s }&.value
  end

  def each_node(node, &)
    yield node
    node.compact_child_nodes.each { each_node(it, &) }
  end

  # The file's constants assigned a plain String, by name.
  def constants(tree)
    found = {}
    each_node(tree) do |node|
      next unless node.is_a?(Prism::ConstantWriteNode) && node.value.is_a?(Prism::StringNode)

      found[node.name] = node.value.unescaped
    end
    found
  end

  # The rules node names, and whether it's a dynamic site.
  def sites(node, constants)
    case node
    when Prism::CallNode then argument(rule_argument(node), constants)
    when Prism::AssocNode then literals(node.key, constants) == ["rule"] ? [literals(node.value, constants), false] : [[], false]
    when Prism::DefNode then [node.name == :rule ? literals(node.body, constants) : [], false]
    when Prism::InstanceVariableWriteNode then [node.name == :@rule ? literals(node.value, constants) : [], false]
    when Prism::LocalVariableWriteNode then [RULE_LOCALS.include?(node.name) ? literals(node.value, constants) : [], false]
    else [[], false]
    end
  end

  # Its rules, and whether it's dynamic: it has no literal, and isn't an
  # interpolated message, whose fixed text has a space, as "no entry
  # #{name}" does and a rule such as "#{kind}_too_large" can't.
  def argument(arg, constants)
    return [[], false] unless arg

    found = literals(arg, constants)
    [found, found.empty? && !message?(arg)]
  end

  def message?(arg)
    arg.is_a?(Prism::InterpolatedStringNode) &&
      arg.parts.any? { it.is_a?(Prism::StringNode) && it.unescaped.match?(/\s/) }
  end

  # The argument of call that holds its rule, or nil. The standard
  # library's errors have no rule, so ErrorFilter calls them internal_error.
  def rule_argument(call)
    args = call.arguments&.arguments || []
    if call.name == :raise && args.size >= 2 && constant?(args[0]) && !STANDARD.include?(args[0].slice)
      args[1]
    elsif call.name == :new && call.receiver && constant?(call.receiver) && call.receiver.slice.match?(ERROR_CLASS) &&
          !STANDARD.include?(call.receiver.slice)
      args[0]
    elsif RULE_CALLS.key?(call.name)
      args[RULE_CALLS[call.name]]
    end
  end

  def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

  # Every Symbol and String literal under node, and every constant the
  # file assigns a String. An interpolated String isn't a literal, and
  # neither is any part of one.
  def literals(node, constants)
    return [] unless node

    found = []
    walk_literals(node, constants, found)
    found
  end

  def walk_literals(node, constants, found)
    case node
    when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then nil
    when Prism::SymbolNode, Prism::StringNode then found << node.unescaped
    when Prism::ConstantReadNode then found << constants[node.name] if constants.key?(node.name)
    else node.compact_child_nodes.each { walk_literals(it, constants, found) }
    end
  end
end
