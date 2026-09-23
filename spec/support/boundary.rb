# frozen_string_literal: true

require "prism"

# Static checks for the line between the driver and the enclave. They run as
# specs, not in production. See spec/boundary_spec.rb for the rules and
# spec/boundary_checker_spec.rb for proof that each check catches a planted
# violation.
#
# These checks can't catch everything. Clever code can hide a require from
# any static check. spec/runtime_boundary_spec.rb runs each side from an
# install that holds only its own dependencies and checks what it loads.
# These checks catch the plain mistakes early, including in code the runtime
# check never runs.
module Boundary
  # What LLM SDKs are loaded as. The enclave must never require any of them.
  # ENCLAVE_ALLOWED_GEMS keeps the gems themselves out. This list catches a
  # require of one, statically and in what the runtime check sees loaded.
  LLM_SDK_REQUIRES = %w[
    anthropic openai ruby_llm langchain gemini-ai cohere ollama-ai mistral-ai
    groq omniai aws-sdk-bedrockruntime google/cloud/ai_platform
  ].freeze

  # Every gem the enclave may load, directly or transitively, besides itself.
  # It's an allowlist, reviewed by hand: boundary_spec.rb fails if the
  # enclave's dependencies don't match it exactly, and
  # runtime_boundary_spec.rb fails if the enclave loads a gem that isn't on
  # it. Never add the driver gem or an LLM SDK.
  ENCLAVE_ALLOWED_GEMS = %w[bigdecimal google-protobuf pg_query quaack-protocol rake].freeze

  ENCLAVE_FORBIDDEN_REQUIRES = ["quaack/driver", *LLM_SDK_REQUIRES].freeze
  # Both sides load the protocol gem, so it obeys both sides' rules.
  PROTOCOL_FORBIDDEN_REQUIRES = ["quaack/enclave", *ENCLAVE_FORBIDDEN_REQUIRES].freeze
  DRIVER_FORBIDDEN_REQUIRES = ["quaack/enclave"].freeze

  REQUIRE_METHODS = %i[require require_relative load autoload].freeze
  EVAL_METHODS = %i[eval instance_eval class_eval module_eval].freeze
  SEND_METHODS = %i[send __send__ public_send].freeze
  # Methods that take method names, so they can reach a require or eval
  # indirectly.
  LOOKUP_METHODS = %i[
    method public_method singleton_method instance_method public_instance_method
    alias_method define_method
  ].freeze
  DANGEROUS_NAMES = [*REQUIRE_METHODS, *EVAL_METHODS, *SEND_METHODS].map(&:to_s).freeze
  LOAD_PATH_GLOBALS = %i[$LOAD_PATH $: $-I].freeze
  SHEBANG = "#!/usr/bin/env ruby"

  Violation = Data.define(:file, :line, :message) do
    def to_s = "#{file}:#{line}: #{message}"
  end

  Closure = Data.define(:names, :unresolved)

  module_function

  # The files of a gem that run when it's loaded or used: its library and its
  # executables.
  def source_files(gem_dir)
    (Dir.glob(File.join(gem_dir, "lib", "**", "*.rb")) +
      Dir.glob(File.join(gem_dir, "exe", "*"))).select { |f| File.file?(f) }.sort
  end

  # Every require in the gem's source files that loads something in
  # `forbidden` or reaches outside the gem, every require the check can't
  # read, and every executable whose shebang isn't exactly SHEBANG.
  def require_violations(gem_dir, forbidden:)
    exe_dir = File.join(File.expand_path(gem_dir), "exe", "")
    source_files(gem_dir).flat_map do |file|
      source = File.read(file)
      shebang = File.expand_path(file).start_with?(exe_dir) ? shebang_violations(file, source) : []
      shebang + scan_source(source, file: file, gem_dir: gem_dir, forbidden: forbidden)
    end
  end

  # Ruby honors options on the shebang line, such as `-rquaack/driver`.
  def shebang_violations(file, source)
    return [] if source.lines.first&.chomp == SHEBANG

    [Violation.new(file, 1, "executable's first line must be exactly #{SHEBANG}")]
  end

  def scan_source(source, file:, gem_dir:, forbidden:)
    result = Prism.parse(source, filepath: file)
    return [Violation.new(file, 1, "doesn't parse, so its requires can't be checked")] unless result.success?

    visitor = RequireVisitor.new(file: file, gem_dir: File.expand_path(gem_dir), forbidden: forbidden)
    result.value.accept(visitor)
    visitor.violations
  end

  # The names of every gem `spec` depends on directly (runtime or
  # development), plus everything those depend on at runtime. `lookup` maps a
  # gem name to its installed spec, or nil. Names it can't look up are listed
  # in `unresolved`, since their own dependencies went unchecked.
  def dependency_closure(spec, lookup: method(:installed_spec))
    names = Set.new
    unresolved = []
    queue = spec.dependencies.dup
    while (dep = queue.shift)
      next unless names.add?(dep.name)

      found = lookup.call(dep.name)
      found ? queue.concat(found.runtime_dependencies) : unresolved << dep.name
    end
    Closure.new(names: names.to_a, unresolved: unresolved)
  end

  # The entry in `forbidden` that the require path `path` loads, or nil.
  # Normalizes the path the way the load path would see it: resolves . and
  # .. segments, drops doubled slashes and a .rb suffix, and ignores case,
  # since a case-insensitive disk loads Quaack/Driver as quaack/driver.
  def forbidden_match(path, forbidden)
    path = File.expand_path(path, "/").delete_prefix("/").delete_suffix(".rb").downcase
    forbidden.find { |lib| path == lib || path.start_with?("#{lib}/") }
  end

  def installed_spec(name)
    Gem::Specification.find_by_name(name)
  rescue Gem::MissingSpecError
    nil
  end

  class RequireVisitor < Prism::Visitor
    attr_reader :violations

    def initialize(file:, gem_dir:, forbidden:)
      super()
      @file = file
      @gem_dir = gem_dir
      @forbidden = forbidden
      @violations = []
    end

    def visit_call_node(node)
      check_call(node)
      super
    end

    def visit_symbol_node(node)
      if REQUIRE_METHODS.map(&:to_s).include?(node.unescaped)
        flag(node, "names #{node.unescaped}, which could call it indirectly")
      end
      super
    end

    # $LOAD_PATH and its aliases are read-only, so every use that changes the
    # load path starts with a read, such as `$:.unshift` or `$: << dir`.
    def visit_global_variable_read_node(node)
      check_global(node)
      super
    end

    private

    def check_call(node)
      case node.name
      when *REQUIRE_METHODS then check_require(node)
      when *SEND_METHODS then check_names(node, [arguments(node).first])
      when *LOOKUP_METHODS then check_names(node, arguments(node))
      else
        flag(node, "#{node.name} of a string can run code this check can't see") if eval_of_string?(node)
      end
    end

    def arguments(node) = node.arguments&.arguments || []

    def eval_of_string?(node)
      node.name == :eval || (EVAL_METHODS.include?(node.name) && !arguments(node).empty?)
    end

    # Each argument must be a plain name that isn't a require, eval, or send.
    def check_names(node, args)
      args.each do |arg|
        name = arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) ? arg.unescaped : nil
        next if name && !DANGEROUS_NAMES.include?(name)

        flag(node, "#{node.name} with #{name ? name.inspect : "a name it can't read"} can call a require indirectly")
      end
    end

    def check_global(node)
      return unless LOAD_PATH_GLOBALS.include?(node.name)

      flag(node, "uses #{node.name}, which changes what a require loads")
    end

    def check_require(node)
      return flag(node, "Bundler.require would load every gem in the shared bundle") if bundler_require?(node)

      arg = required_argument(node)
      return check_required(node, arg.unescaped) if arg.is_a?(Prism::StringNode)

      flag(node, "#{node.name} with an argument that isn't a plain string can't be checked")
    end

    def required_argument(node)
      node.name == :autoload ? arguments(node)[1] : arguments(node)[0]
    end

    def check_required(node, path)
      if node.name == :require_relative || path.start_with?("/")
        check_path(node, File.expand_path(path, File.dirname(@file)))
      elsif path.start_with?("./", "../")
        flag(node, "#{node.name} #{path.inspect} depends on the working directory")
      elsif (hit = forbidden_match(path))
        flag(node, "#{node.name} #{path.inspect} loads #{hit}, which this gem must never load")
      end
    end

    def check_path(node, absolute)
      return if absolute.start_with?("#{@gem_dir}/")

      flag(node, "#{node.name} reaches #{absolute}, outside #{@gem_dir}")
    end

    def forbidden_match(path) = Boundary.forbidden_match(path, @forbidden)

    def bundler_require?(node)
      node.name == :require &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Bundler
    end

    def flag(node, message)
      @violations << Violation.new(@file, node.location.start_line, message)
    end
  end
end
