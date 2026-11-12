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
        # in any case, with a space or a hyphen between words, and so is a
        # run-together one such as HashAggregate, which is no plain word
        # (20261016-13). A one-word type is read only as EXPLAIN capitalizes
        # it, so the SQL keyword LIMIT or the word sort isn't read as a step.
        # Longer names are tried first, so an Index Only Scan isn't read as an
        # Index Scan.
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
        # The one-word types that are also plain words or SQL keywords.
        ONE_WORD = NODE_TYPES.grep_v(/\s|\p{Ll}\p{Lu}/).freeze
        NODE_PATTERN = Regexp.union(
          (NODE_TYPES + NODE_ALIASES.keys).sort_by { -it.size }.map do |name|
            words = name.split.map { Regexp.escape(it) }
            ONE_WORD.include?(name) ? /\b#{words.first}\b/ : /\b#{words.join("[\\s-]+")}\b/i
          end
        )

        # A summary is advice, not the plans retold (20261016-10): it may name
        # plan step types at most this many times in all. Only a name of
        # several words or a run-together one (HashAggregate) counts, since a
        # one-word type such as Limit, Unique, or Sort is also a SQL keyword
        # or a plain word.
        MOST_STEP_NAMES = 2

        # The one-word types that are also English verbs. Where one starts a
        # sentence or a clause after a semicolon, or follows a modal or "to"
        # and is followed by by, an article, or a pronoun, it reads as a verb
        # (Limit what it reads, the rewrite can Hash the input, Sort by date),
        # so it isn't read as a step there (20261016-13, 20261016-16,
        # 20261112-063000-1). Elsewhere in a sentence it's a step (It needs
        # Sort by id). At a sentence's start, a finite verb right after it
        # makes it the subject, so a step (Sort happens later). Any other
        # one-word type, such as Memoize, Materialize, or Gather, is always
        # read as a step. Nor does one read as a verb
        # just after a determiner (a Sort by created_at, the Sort the
        # original had), where it's a noun.
        VERBS = %w[Hash Sort Group Limit Unique Result].freeze
        # A capitalised lead-in word and an optional comma (Then, First,
        # Instead) still leave a sentence start (20261112-080000-1). Only at
        # a sentence's start: "instead of" mid-sentence isn't a lead-in.
        LEAD_IN = /(?:Then|First|Next|Instead|Finally|Also|Otherwise|So),?\s+/
        SENTENCE_START = /(?:\A|[.!?;]\s)\s*(?:#{LEAD_IN.source})?\z/
        MODAL = /\b(?:can|could|should|will|would|may|might|must|to)\s+\z/i
        FINITE_VERB = /\A\s+(?:happens|runs|is|was|takes|costs|dominates|appears|remains)\b/i
        DETERMINER = /\b(?:an?|the|its|their|this|that|each|no)\s+\z/i
        VERB_OBJECT = /\A\s+(?:by|an?|the|its|their|each|every|them|it|rows)\b/i

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

          names = step_names(text)
          return false if names.count { !ONE_WORD.include?(it) } > MOST_STEP_NAMES

          planned = steps(input)
          names.all? do |name|
            step = name.downcase.gsub(/[\s-]+/, " ")
            planned.include?(NODE_ALIASES.fetch(step, step))
          end
        end

        # The node types text names, leaving out a one-word type that reads
        # as a verb.
        def step_names(text)
          text.to_enum(:scan, NODE_PATTERN).filter_map do
            match = Regexp.last_match
            match[0] unless verb?(match)
          end
        end

        # Whether a match is a one-word type that reads as a verb there.
        def verb?(match)
          before = match.pre_match
          after = match.post_match
          return false unless VERBS.include?(match[0]) && !before.match?(DETERMINER)
          return !after.match?(FINITE_VERB) if before.match?(SENTENCE_START)

          before.match?(MODAL) && after.match?(VERB_OBJECT)
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
