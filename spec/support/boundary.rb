# frozen_string_literal: true

require "prism"

# Static checks for the line between the driver and the enclave. They run as
# specs, not in production. See spec/boundary_spec.rb for the rules and
# spec/boundary_checker_spec.rb for proof that each check catches a planted
# violation.
module Boundary
  # Gem names of LLM SDKs. The enclave must never depend on any of them.
  LLM_SDK_GEMS = %w[
    anthropic ruby-anthropic openai ruby-openai ruby_llm langchainrb gemini-ai
    cohere-ruby ollama-ai mistral-ai groq omniai aws-sdk-bedrockruntime
    google-cloud-ai_platform
  ].freeze

  # What those gems are loaded as. The enclave must never require any of them.
  LLM_SDK_REQUIRES = %w[
    anthropic openai ruby_llm langchain gemini-ai cohere ollama-ai mistral-ai
    groq omniai aws-sdk-bedrockruntime google/cloud/ai_platform
  ].freeze

  REQUIRE_METHODS = %i[require require_relative load autoload].freeze
  SEND_METHODS = %i[send __send__ public_send].freeze

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
  # `forbidden` or reaches outside the gem, plus every require the check can't
  # read.
  def require_violations(gem_dir, forbidden:)
    source_files(gem_dir).flat_map do |file|
      scan_source(File.read(file), file: file, gem_dir: gem_dir, forbidden: forbidden)
    end
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
      check(node)
      super
    end

    private

    def check(node)
      if bundler_require?(node)
        flag(node, "Bundler.require would load every gem in the shared bundle")
      elsif kernel_call?(node) && SEND_METHODS.include?(node.name) && sends_require?(node)
        flag(node, "calls a require method indirectly, so it can't be checked")
      elsif kernel_call?(node) && REQUIRE_METHODS.include?(node.name)
        check_require(node)
      end
    end

    def check_require(node)
      arg = required_argument(node)
      return check_required(node, arg.unescaped) if arg.is_a?(Prism::StringNode)

      flag(node, "#{node.name} with an argument that isn't a plain string can't be checked")
    end

    def required_argument(node)
      args = node.arguments&.arguments || []
      node.name == :autoload ? args[1] : args[0]
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

    def forbidden_match(path)
      path = path.delete_suffix(".rb")
      @forbidden.find { |lib| path == lib || path.start_with?("#{lib}/") }
    end

    def kernel_call?(node)
      node.receiver.nil? ||
        (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Kernel)
    end

    def bundler_require?(node)
      node.name == :require &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Bundler
    end

    def sends_require?(node)
      first = node.arguments&.arguments&.first
      first.is_a?(Prism::SymbolNode) && REQUIRE_METHODS.include?(first.unescaped.to_sym)
    end

    def flag(node, message)
      @violations << Violation.new(@file, node.location.start_line, message)
    end
  end
end
