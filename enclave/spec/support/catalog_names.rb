# frozen_string_literal: true

require "prism"
require "pg_query"

# Finds the SQL in the enclave's source and the catalog names in it that
# aren't qualified (task 20260930-14). A search_path can put another schema
# ahead of pg_catalog, and an unqualified name then finds what's planted
# there: a relation, a function, an operator, or a type.
#
#   CatalogNames.scan(root)                  # => { "quaack/enclave/x.rb" => ["line 12: operator =", ...] }
#   CatalogNames.loaded(Quaack::Enclave, root) # => { "quaack/enclave/x.rb" => ["X_SQL, line 12: operator =", ...] }
#
# scan reads the source (Source): every Ruby string literal, plain or
# interpolated, heredocs included, that starts with an upper-case SQL
# keyword (SQL_START). An interpolation of a constant that the same file
# assigns a plain string is inlined. Any other interpolation stands for an
# identifier, a SELECT, a number, a string literal, nothing, or an
# assignment, whichever first lets the whole string parse. A string that
# parses with none must be on SKIP, which says why.
#
# loaded reads every String constant under a loaded namespace that starts
# like SQL (Loaded), so it finds SQL a constant builds from others, such as
# with String#sub, which the source holds only in pieces.
#
# Neither finds SQL a method builds from pieces that don't start with a
# keyword, or SQL built by deparsing a tree.
#
# Flagged:
# - relation: a pg_ relation with no schema.
# - function: any function call with no schema. pg_query already
#   qualifies the SQL-syntax ones, such as EXTRACT and AT TIME ZONE.
# - operator: any operator with no schema, including the ones IN, LIKE,
#   BETWEEN, IS DISTINCT FROM, NULLIF, ANY, ALL, a sublink, and ORDER BY
#   USING use, which can't be qualified and must be rewritten.
# - simple case: CASE x WHEN, which compares with an unqualified =.
# - type: any type name with no schema. pg_query already qualifies the SQL
#   standard ones, such as int, boolean, and json.
# COLLATE isn't checked (task 20261007-3).
module CatalogNames
  SQL_START = /\A\s*(?:SELECT|WITH|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|SET|SHOW|EXPLAIN|PREPARE|EXECUTE|
                 DEALLOCATE|TRUNCATE|COPY|ANALYZE|VACUUM|LOCK|DECLARE|FETCH|RESET|DO|GRANT|REVOKE|COMMENT|
                 SAVEPOINT|RELEASE|BEGIN|COMMIT|ROLLBACK|VALUES|TABLE)\b/x

  # What an interpolation can stand for, tried in order.
  STAND_INS = ["quaack_x", "SELECT 1", "1", "'x'", "", "quaack_x = 1"].freeze

  # Strings that start like SQL but parse with no stand-in, by file and the
  # string's start, with why.
  SKIP = {
    ["quaack/enclave/build_connection.rb", "CREATE INDEX "] => "a LIKE pattern passed as a parameter",
    ["quaack/enclave/deparse.rb", "SELECT WHERE "] => "a prefix pg_query deparses a bare expression after",
    ["quaack/enclave/name_qualifier/reg_literal.rb", "SELECT NULL::"] => "a prefix a regtype literal is read after",
    ["quaack/enclave/index_ddl_check.rb", "WITH (...)"] => "the name of a refused form",
    ["quaack/enclave/insert_check.rb", "WITH"] => "the name of a refused form",
    ["quaack/enclave/steps/index_build.rb", "CREATE INDEX "] => "a replacement String#sub writes into DDL",
    ["quaack/enclave/clock_defaults.rb", "TABLE ONLY "] => "the middle of an ALTER TABLE built in pieces",
    ["quaack/enclave/clock_defaults.rb", "ALTER "] => "the end of an ALTER TABLE built in pieces",
    ["quaack/enclave/rewrite_rules/catalog/types.rb", "SELECT NULL::%s"] => "a cast pg_query parses, never run"
  }.freeze

  # The 29 files catalog_names_spec's list of files not yet qualified held
  # when task 20260930-14 made it. That list may only shrink, so it must
  # stay within these. Never add a file here: qualify the file instead.
  NOT_YET_QUALIFIED_AT_START = %w[
    quaack/enclave/arena.rb quaack/enclave/arena_runner/deferred.rb quaack/enclave/arena_runner/pipeline.rb
    quaack/enclave/arena_runner/sequences.rb quaack/enclave/arena_schema.rb
    quaack/enclave/arena_schema/domain_checks.rb quaack/enclave/arena_schema/unique_indexes.rb
    quaack/enclave/assumption_check.rb quaack/enclave/assumption_check/denormalized_equal.rb
    quaack/enclave/clock_defaults.rb quaack/enclave/counterexamples/evaluated.rb
    quaack/enclave/denormalized_fixture.rb quaack/enclave/insert_check.rb quaack/enclave/insert_clock_words.rb
    quaack/enclave/insert_values.rb quaack/enclave/result_comparison/tiebreaker.rb
    quaack/enclave/rewrite_candidate_check.rb quaack/enclave/rewrite_rules/catalog.rb
    quaack/enclave/rewrite_rules/catalog/calls.rb quaack/enclave/rewrite_rules/catalog/foreign_keys.rb
    quaack/enclave/rewrite_rules/catalog/types.rb quaack/enclave/rewrite_rules/existence_in_flip.rb
    quaack/enclave/scenarios/ties.rb quaack/enclave/scenarios/types.rb quaack/enclave/scenarios/values.rb
    quaack/enclave/server_clock.rb quaack/enclave/steps/index_search.rb quaack/enclave/steps/rewrite_check.rb
    quaack/enclave/value_pools.rb
  ].freeze

  # A string of SQL: where it is, and its parse, nil for one on SKIP.
  # label names it in a finding, such as "line 12".
  Site = Data.define(:file, :label, :text, :parse)

  # What each node with a name to check is flagged as, if anything.
  FLAGS = {
    PgQuery::RangeVar => ->(n) { n.schemaname.empty? && n.relname.start_with?("pg_") ? ["relation #{n.relname}"] : [] },
    PgQuery::FuncCall => ->(n) { one_part(n.funcname, "function") },
    PgQuery::A_Expr => ->(n) { one_part(n.name, "operator") },
    PgQuery::SubLink => ->(n) { sublink(n) },
    PgQuery::SortBy => ->(n) { one_part(n.use_op, "operator") },
    PgQuery::CaseExpr => ->(n) { n.arg ? ["simple case"] : [] },
    PgQuery::TypeName => ->(n) { one_part(n.names, "type") }
  }.freeze

  module_function

  def scan(root) = Source.sites(root).transform_values { |all| all.flat_map { violations(it) } }.reject { _2.empty? }

  def loaded(namespace, root)
    found = Hash.new { |h, k| h[k] = [] }
    Loaded.sites(namespace, root).each { found[it.file].concat(violations(it)) }
    found.reject { _2.empty? }
  end

  # The files on list that NOT_YET_QUALIFIED_AT_START doesn't have.
  def added(list) = list - NOT_YET_QUALIFIED_AT_START

  def parse(text)
    PgQuery.parse(text)
  rescue PgQuery::ParseError
    nil
  end

  def violations(site)
    return [] unless site.parse

    found = []
    site.parse.walk! { |node| found.concat(FLAGS[node.class]&.call(node) || []) }
    found.map { "#{site.label}: #{it}" }
  end

  # x IN (SELECT ...) has no operator name: it means an unqualified =.
  def sublink(node)
    return [] unless %i[ANY_SUBLINK ALL_SUBLINK ROWCOMPARE_SUBLINK].include?(node.sub_link_type)

    node.oper_name.empty? ? ["operator ="] : one_part(node.oper_name, "operator")
  end

  def one_part(names, what) = names.size == 1 ? ["#{what} #{names.first.string.sval}"] : []

  # The source's SQL strings.
  module Source
    module_function

    # file => [Site], every SQL string found in each Ruby file under root.
    def sites(root)
      Dir.glob("**/*.rb", base: root).sort.to_h do |file|
        program = Prism.parse_file(File.join(root, file)).value
        constants = constants(program)
        [file, strings(program).filter_map { site(file, it, constants) }]
      end
    end

    def site(file, node, constants)
      texts = texts(node, constants)
      return unless texts.first.match?(SQL_START)

      label = "line #{node.location.start_line}"
      parse = texts.lazy.filter_map { CatalogNames.parse(it) }.first
      raise "#{file}, #{label}: SQL that parses with no stand-in and isn't on SKIP" unless parse || skip?(file, texts)

      Site.new(file:, label:, text: texts.first, parse:)
    end

    def skip?(file, texts) = SKIP.keys.any? { |f, start| f == file && texts.first.start_with?(start) }

    # Every string literal in a program, not counting the parts of an
    # interpolated one.
    def strings(node, found = [])
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then found << node
      when Prism::Node then node.compact_child_nodes.each { strings(it, found) }
      end
      found
    end

    # NAME => its plain string, for each constant a program assigns one.
    def constants(node, found = {})
      return found unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::ConstantWriteNode)
        value = node.value
        value = value.receiver while value.is_a?(Prism::CallNode) && value.name == :freeze && value.receiver
        found[node.name] = value.unescaped if value.is_a?(Prism::StringNode)
      end
      node.compact_child_nodes.each { constants(it, found) }
      found
    end

    # The string's text with each combination of stand-ins, the first
    # stand-in's first.
    def texts(node, constants)
      return [node.unescaped] if node.is_a?(Prism::StringNode)

      choices = node.parts.grep_v(Prism::StringNode).map { |hole| (value = constant(hole, constants)) ? [value] : STAND_INS }
      combinations = choices.empty? ? [[]] : choices.first.product(*choices.drop(1))
      combinations.map { |picks| fill(node.parts, picks.dup) }
    end

    def fill(parts, picks) = parts.map { it.is_a?(Prism::StringNode) ? it.unescaped : picks.shift }.join

    def constant(hole, constants)
      body = hole.is_a?(Prism::EmbeddedStatementsNode) && hole.statements&.body
      return unless body && body.size == 1 && body.first.is_a?(Prism::ConstantReadNode)

      constants[body.first.name]
    end
  end

  # A loaded namespace's SQL constants.
  module Loaded
    module_function

    # [Site], each String constant under namespace that starts like SQL,
    # parses, and is defined in a file under root.
    def sites(namespace, root)
      found = []
      each_constant(namespace) do |owner, name, value|
        next unless value.is_a?(String) && value.match?(SQL_START) && (parse = CatalogNames.parse(value))

        file, line = own(owner, :const_source_location, name)
        next unless file&.start_with?("#{root}/")

        found << Site.new(file: file.delete_prefix("#{root}/"), label: "#{name}, line #{line}", text: value, parse:)
      end
      found
    end

    def each_constant(namespace, seen = {}, &)
      return if seen[namespace]

      seen[namespace] = true
      own(namespace, :constants, false).each do |name|
        next if own(namespace, :autoload?, name)

        value = own(namespace, :const_get, name, false)
        yield namespace, name, value
        each_constant(value, seen, &) if inner?(namespace, value)
      end
    end

    def inner?(namespace, value) = value.is_a?(Module) && own(value, :name)&.start_with?("#{own(namespace, :name)}::")

    # Module's own method, even where a module defines one of the same
    # name, as a module_function constants or name.
    def own(mod, method, *) = Module.instance_method(method).bind_call(mod, *)
  end
end
