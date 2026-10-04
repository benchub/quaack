# frozen_string_literal: true

require_relative "index_candidate"
require_relative "statistics"
require_relative "plan_node"
require_relative "plan_columns"
require_relative "generator_two_patterns"

module Quaack
  module Enclave
    # Generator two (DESIGN.md's index-from-plan): index candidates from the problem patterns
    # in the production plan.
    #
    #   GeneratorTwo.candidates(explain, statistics:, schemas: ["public"])
    #   # => [#<data Quaack::Enclave::IndexCandidate ...>, ...]
    #
    # explain is the parsed JSON of EXPLAIN (ANALYZE, BUFFERS, SETTINGS,
    # FORMAT JSON): the top-level array Postgres prints. statistics is a
    # Statistics. schemas, if given, is the schemas the query touches, to
    # settle a table name that's in more than one (see PlanColumns). The
    # result is a frozen, duplicate-free array of candidates, each with
    # sources [:plan]. It comes in the order of a depth-first walk of the
    # plan, InitPlans and SubPlans included, and within a node in the order
    # of GeneratorTwoPatterns#patterns. The same input always gives
    # the same output.
    #
    # analyzed: false is for a plain EXPLAIN, such as a rewrite's racetrack
    # plan (DESIGN.md's plan-pruning). It has no actual rows and no rows removed, so
    # only the patterns that need neither run: the BitmapAnd/BitmapOr, Sort,
    # and aggregate patterns. The others are skipped, even if the plan has
    # actual rows.
    #
    # The thresholds are keyword arguments, each a finite, non-negative
    # number:
    #
    # - most_rows_removed (0.9): a Seq Scan's filter removes at least this
    #   fraction of the rows it read. A `col = literal` conjunct removes most
    #   rows on its own when 1 - the literal's
    #   TableStatistics#value_frequency is at least this too.
    # - many_rows_removed (0.5) and many_rows_min (1,000): an Index Scan's or
    #   Bitmap Heap Scan's Filter and index recheck remove at least this
    #   fraction of the rows it fetched, and at least this many rows over all
    #   its loops.
    # - expensive_inner_rows (10,000): a Nested Loop's inner side returns at
    #   least this many rows over all its loops: Actual Loops times Actual
    #   Rows.
    # - large_hash_rows (100,000) and large_hash_batches (2): a Hash node's
    #   Actual Rows is at least the first, or its Hash Batches is at least
    #   the second.
    #
    # Trust boundary: a partial-index candidate's predicate holds a real
    # literal from the plan, so the result is value-class data until index-dedupe
    # filters it. This module sends nothing anywhere. No error it raises
    # includes anything from the plan. PlanNode and PlanColumns::Conjunct,
    # the helpers that hold plan text, leave it out of inspect, so nothing
    # that inspects them, or the helpers that hold them, shows it either.
    module GeneratorTwo
      THRESHOLDS = {
        most_rows_removed: 0.9, many_rows_removed: 0.5, many_rows_min: 1_000,
        expensive_inner_rows: 10_000, large_hash_rows: 100_000, large_hash_batches: 2
      }.freeze

      module_function

      def candidates(explain, statistics:, schemas: nil, analyzed: true, **thresholds)
        raise ArgumentError, "statistics must be a Statistics" unless statistics.is_a?(Statistics)
        unless schemas.nil? || (schemas.is_a?(Array) && schemas.all?(String))
          raise ArgumentError, "schemas must be nil or an Array of schema names"
        end

        explain_roots = roots(explain)
        check_analyze(explain) if analyzed
        Walk.new(explain_roots, statistics, schemas, check_thresholds(thresholds), analyzed).candidates
      end

      def roots(explain)
        valid = explain.is_a?(Array) && !explain.empty? && explain.all? { |e| e.is_a?(Hash) && e["Plan"].is_a?(Hash) }
        raise ArgumentError, "explain must be the parsed JSON of EXPLAIN (FORMAT JSON)" unless valid

        explain.map { |e| PlanNode.new(e["Plan"]) }
      end

      # DESIGN.md's input: the rows removed and actual rows come only from ANALYZE.
      def check_analyze(explain)
        return if explain.all? { |e| e["Plan"].key?("Actual Loops") }

        raise ArgumentError, "explain must come from EXPLAIN ANALYZE, and this plan has no actual row counts"
      end

      def check_thresholds(given)
        unknown = given.keys - THRESHOLDS.keys
        raise ArgumentError, "unknown thresholds: #{unknown.join(", ")}" if unknown.any?

        THRESHOLDS.merge(given).each do |name, value|
          next if value.is_a?(Numeric) && value.real? && value.to_f.finite? && !value.negative?

          raise ArgumentError, "#{name} must be a finite, non-negative number"
        end
      end

      private_class_method :roots, :check_analyze, :check_thresholds

      # One call's walk over one plan. It holds the plan only for the length
      # of the call.
      class Walk
        include GeneratorTwoPatterns

        def initialize(roots, statistics, schemas, thresholds, analyzed)
          @nodes = roots.flat_map(&:subtree)
          @columns = PlanColumns.new(@nodes, statistics, schemas)
          @thresholds = thresholds
          @analyzed = analyzed
        end

        def candidates
          @nodes.flat_map { |node| @analyzed ? patterns(node) : estimated_patterns(node) }.uniq.freeze
        end

        private

        attr_reader :columns, :thresholds

        # The patterns check what the constructor would refuse before they
        # build, so a refusal here is a bug, and it raises.
        def build(table, **) = IndexCandidate.new(table: table.name, sources: [:plan], **)

        # An existing index with more columns, as a plain candidate.
        def extend_index(existing, **) = existing.with(**, unique: false, sources: [:plan])

        # Whether a value meets a threshold. nil (an unknown frequency) and
        # NaN (the removed fraction of a node that read no rows) never do.
        def at_least?(value, threshold) = !value.nil? && value >= thresholds.fetch(threshold)

        # The TableStatistics a scan node of one of the types reads, or nil.
        def scan_table(node, *types) = (columns.table(node) if types.include?(node.type))

        # A scan's conjuncts under its own alias.
        def scan_conjuncts(scan, keys = SCAN_QUALS) = columns.conjuncts(scan, keys, scan.alias_name)

        # The columns under alias_name in the conjuncts: the :constant ones
        # first if constant_first, then the rest, in order, without repeats.
        def own_columns(conjuncts, alias_name, constant_first: false)
          ordered = constant_first ? conjuncts.partition { |c| c.kind == :constant }.flatten : conjuncts
          ordered.flat_map(&:columns).select { |c| c.alias_name == alias_name }.uniq
        end

        def constant_columns(conjuncts, alias_name)
          own_columns(conjuncts.select { |c| c.kind == :constant }, alias_name)
        end

        # Most selective first, and unknown selectivity last, keeping the
        # plan's order among equals.
        def by_selectivity(columns)
          columns.each_with_index.sort_by do |column, i|
            selectivity = selectivity(column)
            [selectivity ? 0 : 1, selectivity || 0, i]
          end.map(&:first)
        end

        def selectivity(column)
          column.table.equality_selectivity(column.name) if column.table.column?(column.name)
        end
      end

      private_constant :Walk
    end
  end
end
