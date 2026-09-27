# frozen_string_literal: true

require "prism"

# Static checks for the line between the driver and the enclave. They run as
# specs, not in production. spec/boundary_spec.rb runs them on the real gems,
# and spec/boundary_checker_spec.rb proves each one catches a planted
# violation.
#
# They catch honest mistakes, not deliberate evasion (see
# spec/support/runtime_boundary.rb). spec/runtime_boundary_spec.rb loads every
# lib file and flags anything forbidden that loads, so these checks only add
# a precise message and cover code that never runs, such as a require inside
# a method body. So they look almost only at plain string requires:
#
# - A require, load, or autoload of a forbidden library, such as
#   quaack/driver or openai in the enclave, or quaack/enclave in the driver.
#   This is the only rule for the driver (`names_only`), apart from
#   flagging a file that doesn't parse, since loading enclave code on a
#   laptop leaks no production data. So the driver's check misses a
#   require_relative into the enclave's tree, and doesn't check its
#   executable's shebang. The runtime check still flags enclave code that
#   loads.
# - A require_relative or absolute path that leaves the gem, such as into the
#   driver's tree, or a path relative to the working directory.
# - A require or require_relative of a path that isn't a plain string, which
#   this check can't read.
# - Bundler.require, which would load every gem in the shared bundle. The
#   runtime check catches it at the top level, since it runs from the repo
#   and Bundler finds the repo's Gemfile, but not in code that never runs.
#   On a jump server with no Gemfile it just raises.
# - An executable whose shebang isn't exactly SHEBANG.
#
# They don't look at send, define_method, symbols, eval, or $LOAD_PATH.
# Hiding a require behind those takes intent, and ordinary code uses them.
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
  ENCLAVE_ALLOWED_GEMS = %w[bigdecimal google-protobuf pg pg_query quaack-protocol rake].freeze

  ENCLAVE_FORBIDDEN_REQUIRES = ["quaack/driver", *LLM_SDK_REQUIRES].freeze
  # Both sides load the protocol gem, so it obeys both sides' rules.
  PROTOCOL_FORBIDDEN_REQUIRES = ["quaack/enclave", *ENCLAVE_FORBIDDEN_REQUIRES].freeze
  DRIVER_FORBIDDEN_REQUIRES = ["quaack/enclave"].freeze

  REQUIRE_METHODS = %i[require require_relative load autoload].freeze
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

  # Every violation of the rules above in the gem's source files. With
  # `names_only`, only requires of something in `forbidden` and files that
  # don't parse count.
  def require_violations(gem_dir, forbidden:, names_only: false)
    exe_dir = File.join(File.expand_path(gem_dir), "exe", "")
    source_files(gem_dir).flat_map do |file|
      source = File.read(file)
      exe = !names_only && File.expand_path(file).start_with?(exe_dir)
      shebang = exe ? shebang_violations(file, source) : []
      shebang + scan_source(source, file: file, gem_dir: gem_dir, forbidden: forbidden, names_only: names_only)
    end
  end

  # Ruby honors options on the shebang line, such as `-rquaack/driver`.
  def shebang_violations(file, source)
    return [] if source.lines.first&.chomp == SHEBANG

    [Violation.new(file, 1, "executable's first line must be exactly #{SHEBANG}")]
  end

  def scan_source(source, file:, gem_dir:, forbidden:, names_only: false)
    result = Prism.parse(source, filepath: file)
    return [Violation.new(file, 1, "doesn't parse, so its requires can't be checked")] unless result.success?

    visitor = RequireVisitor.new(file: file, gem_dir: File.expand_path(gem_dir), forbidden:, names_only:)
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

    def initialize(file:, gem_dir:, forbidden:, names_only:)
      super()
      @file = file
      @gem_dir = gem_dir
      @forbidden = forbidden
      @names_only = names_only
      @violations = []
    end

    # Any receiver counts, so Kernel.require is checked too.
    def visit_call_node(node)
      check_require(node) if REQUIRE_METHODS.include?(node.name)
      super
    end

    private

    def check_require(node)
      arg = required_argument(node)
      path = arg.unescaped if arg.is_a?(Prism::StringNode)
      return check_name(node, path) if @names_only
      return flag(node, "Bundler.require would load every gem in the shared bundle") if bundler_require?(node)
      return check_required(node, path) if path

      # The one rule for a path that isn't a plain string, kept because
      # `require File.expand_path("../../../driver/lib/quaack/driver", __dir__)`
      # is a common older idiom, and in code that never runs no other check
      # sees it. load and autoload stay exempt, so JSON.load(text) passes.
      return unless arg && %i[require require_relative].include?(node.name)

      flag(node, "#{node.name} of a path this check can't read, so it can't tell what it loads")
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
      else
        check_name(node, path)
      end
    end

    def check_name(node, path)
      return unless path && (hit = Boundary.forbidden_match(path, @forbidden))

      flag(node, "#{node.name} #{path.inspect} loads #{hit}, which this gem must never load")
    end

    def check_path(node, absolute)
      return if absolute.start_with?("#{@gem_dir}/")

      flag(node, "#{node.name} reaches #{absolute}, outside #{@gem_dir}")
    end

    # Bundler or ::Bundler, not Mine::Bundler.
    def bundler_require?(node)
      receiver = node.receiver
      node.name == :require &&
        (receiver.is_a?(Prism::ConstantReadNode) ||
          (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)) &&
        receiver.name == :Bundler
    end

    def flag(node, message)
      @violations << Violation.new(@file, node.location.start_line, message)
    end
  end
end
