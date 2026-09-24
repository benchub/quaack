# frozen_string_literal: true

module Quaack
  module Enclave
    module Redaction
      # The whitelist of EXPLAIN (FORMAT JSON) fields a redacted plan keeps
      # (see Plan), by what each holds.
      module PlanFields
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

        # Whether a value is what a name, number, or flag field should hold.
        SCALARS = { name: ->(value) { value.is_a?(String) }, number: ->(value) { value.is_a?(Numeric) },
                    flag: ->(value) { [true, false].include?(value) } }.freeze

        # What each field on the whitelist holds.
        KINDS = { name: NAMES, number: NUMBERS, flag: FLAGS, expression: EXPRESSIONS,
                  expressions: EXPRESSION_LISTS }.flat_map { |kind, keys| keys.map { |key| [key, kind] } }.to_h.freeze
      end

      private_constant :PlanFields
    end
  end
end
