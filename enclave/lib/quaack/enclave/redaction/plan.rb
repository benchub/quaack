# frozen_string_literal: true

require_relative "expression"

module Quaack
  module Enclave
    module Redaction
      # Builds a redacted copy of an EXPLAIN (FORMAT JSON) plan. See
      # Redaction.plan.
      #
      # The copy is built from a whitelist, not scrubbed: each field below
      # is copied (a name, number, or flag, when its value is that kind) or
      # redacted (an expression, through Expression), and every other field
      # is left out, so a field a later Postgres adds is dropped until
      # someone adds it here. The fields are the ones Postgres 18 prints for
      # a SELECT, with ANALYZE, BUFFERS, SETTINGS, VERBOSE, WAL, and
      # MEMORY. Among those left out:
      # - Workers (per-worker counts), Full-sort Groups and Pre-sorted
      #   Groups (an Incremental Sort's details), Grouping Sets (which
      #   SupportedSql refuses), and Params Evaluated.
      # - Anything from an extension, such as postgres_fdw's Remote SQL,
      #   which is a whole query with its literals.
      # - JIT, Triggers, Query Identifier, and Serialization.
      class Plan
        NAMES = ["Node Type", "Strategy", "Partial Mode", "Parent Relationship", "Subplan Name", "Relation Name",
                 "Schema", "Alias", "CTE Name", "Function Name", "Tuplestore Name", "Index Name", "Join Type",
                 "Scan Direction", "Command", "Sort Method", "Sort Space Type", "Cache Mode", "Storage"].freeze

        BUFFERS = %w[Shared Local Temp].product(%w[Hit Read Dirtied Written])
                                       .map { |kind, what| "#{kind} #{what} Blocks" }.freeze

        IO_TIMES = %w[Shared Local Temp].product(%w[Read Write]).map { |kind, what| "#{kind} I/O #{what} Time" }.freeze

        NUMBERS = ["Startup Cost", "Total Cost", "Plan Rows", "Plan Width", "Actual Startup Time",
                   "Actual Total Time", "Actual Rows", "Actual Loops", "Rows Removed by Filter",
                   "Rows Removed by Index Recheck", "Rows Removed by Join Filter", "Heap Fetches", "Index Searches",
                   "Exact Heap Blocks", "Lossy Heap Blocks", "Sort Space Used", "Hash Buckets",
                   "Original Hash Buckets", "Hash Batches", "Original Hash Batches", "Peak Memory Usage",
                   "Disk Usage", "Planned Partitions", "HashAgg Batches", "Cache Hits", "Cache Misses",
                   "Cache Evictions", "Cache Overflows", "Estimated Capacity", "Estimated Distinct Lookup Keys",
                   "Estimated Lookups", "Estimated Hit Percent", "Workers Planned", "Workers Launched",
                   "Subplans Removed", "Maximum Storage", "WAL Records", "WAL FPI", "WAL Bytes",
                   "WAL Buffers Full", *BUFFERS, *IO_TIMES].freeze

        FLAGS = ["Parallel Aware", "Async Capable", "Inner Unique", "Single Copy", "Disabled"].freeze

        EXPRESSIONS = ["Filter", "Index Cond", "Recheck Cond", "Join Filter", "Hash Cond", "Merge Cond", "TID Cond",
                       "One-Time Filter", "Run Condition", "Order By", "Cache Key", "Function Call", "Window"].freeze

        EXPRESSION_LISTS = ["Output", "Sort Key", "Presorted Key", "Group Key"].freeze

        # The quals whose node consumes a placeholder they hold, for its row
        # counts. A Recheck Cond only repeats the Index Cond of the bitmap
        # index scans under it, so it isn't one.
        CONSUMERS = (EXPRESSIONS.take(10) - ["Recheck Cond"]).freeze

        TOP_NUMBERS = ["Planning Time", "Execution Time"].freeze

        PLANNING = [*BUFFERS, *IO_TIMES, "Memory Used", "Memory Allocated"].freeze

        # The settings Postgres 18 marks GUC_EXPLAIN, the only ones EXPLAIN
        # (SETTINGS) lists, from pg_settings_get_flags. Each is a planner or
        # resource setting, and its value is a setting, never row data, so
        # the Settings object keeps them. search_path is schema names. A
        # setting not listed here, such as one an extension adds, is left
        # out.
        SETTINGS = %w[
          constraint_exclusion cpu_index_tuple_cost cpu_operator_cost cpu_tuple_cost cursor_tuple_fraction
          debug_parallel_query effective_cache_size effective_io_concurrency enable_async_append enable_bitmapscan
          enable_distinct_reordering enable_gathermerge enable_group_by_reordering enable_hashagg enable_hashjoin
          enable_incremental_sort enable_indexonlyscan enable_indexscan enable_material enable_memoize
          enable_mergejoin enable_nestloop enable_parallel_append enable_parallel_hash enable_partition_pruning
          enable_partitionwise_aggregate enable_partitionwise_join enable_presorted_aggregate
          enable_self_join_elimination enable_seqscan enable_sort enable_tidscan from_collapse_limit geqo
          geqo_effort geqo_generations geqo_pool_size geqo_seed geqo_selection_bias geqo_threshold
          hash_mem_multiplier jit jit_above_cost jit_inline_above_cost jit_optimize_above_cost join_collapse_limit
          maintenance_io_concurrency max_parallel_workers max_parallel_workers_per_gather
          min_parallel_index_scan_size min_parallel_table_scan_size parallel_leader_participation
          parallel_setup_cost parallel_tuple_cost plan_cache_mode random_page_cost recursive_worktable_factor
          search_path seq_page_cost temp_buffers work_mem
        ].to_set.freeze

        # One place a placeholder was found: the plan node's own fields and
        # the qual that held it.
        Consumer = Data.define(:fields, :qual)

        attr_reader :explain, :masked, :dropped

        # consumers maps each placeholder's number to every Consumer of it.
        attr_reader :consumers

        def initialize(explain, matcher)
          valid = explain.is_a?(Array) && !explain.empty? && explain.all? { |e| e.is_a?(Hash) && e["Plan"].is_a?(Hash) }
          raise ArgumentError, "explain must be the parsed JSON of EXPLAIN (FORMAT JSON)" unless valid

          @matcher = matcher
          @masked = 0
          @dropped = 0
          @consumers = Hash.new { |h, k| h[k] = [] }
          @explain = explain.map { |entry| statement(entry) }.freeze
        end

        private

        def statement(entry)
          out = { "Plan" => node(entry["Plan"]) }
          settings = entry["Settings"]
          out["Settings"] = settings.select { |name, value| SETTINGS.include?(name) && value.is_a?(String) } if
            settings.is_a?(Hash)
          out["Planning"] = numbers(entry["Planning"], PLANNING) if entry["Planning"].is_a?(Hash)
          out.merge!(numbers(entry, TOP_NUMBERS))
        end

        def numbers(fields, keys) = fields.slice(*keys).select { |_key, value| value.is_a?(Numeric) }

        # The walk keeps its own stack of nodes still to copy, rather than
        # recursing, so a plan of any depth can't overflow Ruby's stack.
        def node(root)
          out = {}
          pending = [[root, out]]
          until pending.empty?
            fields, copy = pending.pop
            copy_fields(fields, copy, pending)
          end
          out
        end

        def copy_fields(fields, copy, pending)
          raise ArgumentError, "explain has a plan node that isn't an object" unless fields.is_a?(Hash)

          fields.each do |key, value|
            kept = key == "Plans" ? plans(value, pending) : field(fields, key, value)
            kept == :drop ? (@dropped += 1) : (copy[key] = kept unless kept.nil?)
          end
        end

        # The field's redacted value, nil if it isn't on the whitelist, or
        # :drop if it is, but its value can't be kept.
        def field(fields, key, value)
          if NAMES.include?(key) then value.is_a?(String) ? value : :drop
          elsif NUMBERS.include?(key) then value.is_a?(Numeric) ? value : :drop
          elsif FLAGS.include?(key) then [true, false].include?(value) ? value : :drop
          elsif EXPRESSIONS.include?(key) then expression(fields, key, value)
          elsif EXPRESSION_LISTS.include?(key) then expression_list(value)
          end
        end

        # Empty copies of the children, which the walk fills in later.
        def plans(value, pending)
          raise ArgumentError, "explain has a Plans entry that isn't a list" unless value.is_a?(Array)

          value.map { |child| {}.tap { |copy| pending << [child, copy] } }
        end

        def expression(fields, key, value)
          redacted = Expression.redact(value, @matcher)
          return :drop unless redacted

          @masked += redacted.masked
          redacted.matches.flatten.uniq.each { |n| @consumers[n] << Consumer.new(fields:, qual: key) } if
            CONSUMERS.include?(key)
          redacted.text
        end

        # A list is dropped whole if any of it can't be read, since each
        # entry's place in it means something.
        def expression_list(value)
          return :drop unless value.is_a?(Array)

          redacted = value.map { |text| Expression.redact(text, @matcher) }
          return :drop unless redacted.all?

          @masked += redacted.sum(&:masked)
          redacted.map(&:text)
        end
      end

      private_constant :Plan
    end
  end
end
