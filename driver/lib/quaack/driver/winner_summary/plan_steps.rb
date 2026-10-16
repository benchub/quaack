# frozen_string_literal: true

module Quaack
  module Driver
    class WinnerSummary
      # The guard's check on the plan steps a summary names: each must be a
      # step one of the two plans has, with no join or parallel qualifier,
      # and a summary may name them only a few times, since it's advice, not
      # the plans retold.
      module PlanSteps
        # Postgres's plan node types, as EXPLAIN names them. A summary may name
        # one only if a plan in the input has it. One of several words is read
        # in any case, with a space or a hyphen between words; a one-word type
        # only as EXPLAIN capitalizes it, so the SQL keyword LIMIT or the word
        # sort isn't read as a step. Longer names are tried first, so an Index
        # Only Scan isn't read as an Index Scan.
        NODE_TYPES = [
          "Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan", "Tid Scan",
          "Tid Range Scan", "Subquery Scan", "Function Scan", "Table Function Scan", "Values Scan", "CTE Scan",
          "Named Tuplestore Scan", "WorkTable Scan", "Foreign Scan", "Custom Scan", "Sample Scan", "Nested Loop",
          "Hash Join", "Merge Join", "Hash", "Sort", "Incremental Sort", "Aggregate", "HashAggregate",
          "GroupAggregate", "MixedAggregate", "Group", "Unique", "Limit", "Append", "Merge Append", "Materialize",
          "Memoize", "Gather", "Gather Merge", "SetOp", "HashSetOp", "Recursive Union", "BitmapAnd", "BitmapOr",
          "Result", "ProjectSet", "LockRows", "WindowAgg", "ModifyTable"
        ].freeze
        NODE_ALIASES = { "sequential scan" => "seq scan" }.freeze
        NODE_PATTERN = Regexp.union(
          (NODE_TYPES + NODE_ALIASES.keys).sort_by { -it.size }.map do |name|
            words = name.split.map { Regexp.escape(it) }
            words.size == 1 ? /\b#{words.first}\b/ : /\b#{words.join("[\\s-]+")}\b/i
          end
        )

        # A summary is advice, not the plans retold (20261016-10): it may name
        # plan step types at most this many times in all. Only a name of
        # several words or a run-together one (HashAggregate) counts, since a
        # one-word type such as Limit, Unique, or Sort is also a SQL keyword
        # or a plain word.
        MOST_STEP_NAMES = 2
        JARGON = /\s|-|\p{Ll}\p{Lu}/

        # A join or parallel qualifier on a node type: Hash Anti Join, a semi
        # join, a Parallel Seq Scan. The payload's plan nodes carry only the
        # bare node type, not EXPLAIN's Join Type or Parallel Aware, so no
        # summary can back one, and the check refuses it outright
        # (20261010-37).
        QUALIFIED = Regexp.union(/\b(?:anti|semi)(?:[\s-]+|-?)join\b/i,
                                 /\b(?:hash|merge|nested[\s-]+loop)[\s-]+(?:anti|semi)\b/i,
                                 /\bparallel[\s-]+(?:#{NODE_PATTERN.source})/i)

        module_function

        # Whether every plan node type text names is a step of the original's
        # plan or the winner's, with no join or parallel qualifier, and text
        # names no more than MOST_STEP_NAMES of them.
        def planned?(text, input)
          return false if text.match?(QUALIFIED)

          names = text.scan(NODE_PATTERN)
          return false if names.count { it.match?(JARGON) } > MOST_STEP_NAMES

          planned = steps(input)
          names.all? do |name|
            step = name.downcase.gsub(/[\s-]+/, " ")
            planned.include?(NODE_ALIASES.fetch(step, step))
          end
        end

        # The node types of the original's plan and the winner's, downcased.
        def steps(input)
          [input.dig("original", "plan"), input.dig("winner", "plan")].flat_map { Array(it) }
                                                                      .filter_map { it["step"]&.downcase }
        end
      end
    end
  end
end
