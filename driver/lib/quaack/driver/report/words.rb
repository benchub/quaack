# frozen_string_literal: true

require_relative "../rewrite_names"

module Quaack
  module Driver
    module Report
      # The report's fixed English for the names the payload carries. The
      # payload's names are QUAACK's own constants (stages, reasons, fates,
      # scenarios), which mean nothing to a reader who hasn't read
      # DESIGN.md, so the report never prints one where it has words.
      module Words
        MISSING = "not recorded"

        SETS = { "slow" => "slow", "worst_case" => "worst case", "typical" => "typical" }.freeze
        VERDICTS = { "better" => "better", "no_worse" => "no worse", "worse" => "worse" }.freeze

        # rewrite-test's scenarios, by the test data each one loads.
        SCENARIOS = { "s0" => "empty tables", "s1" => "rows that just match and just miss", "s2" => "NULLs",
                      "s3" => "duplicate join keys", "s4" => "rows with no join partner",
                      "s5" => "extreme values", "s6" => "groups of one, many, and none" }.freeze

        # Why a test ended without comparing results. Any other rule is a
        # statement that failed on the test database.
        FAILURES = { "unsupported_order" => "the order of your query's rows can't be checked",
                     "statement_timeout" => "a statement timed out",
                     "statement_canceled" => "a statement was canceled" }.freeze
        FAILED = "a statement failed on the test database"

        # Why rewrite-test couldn't make up test data for the query, by its rule.
        REFUSALS = { "fk_cycle" => "its tables' foreign keys form a cycle QUAACK can't load",
                     "complex_check" => "a CHECK constraint on its tables is too complex for QUAACK to satisfy",
                     "unsatisfiable_check" => "no value QUAACK tried passes a CHECK constraint on its tables",
                     "expression_unique_index" => "a unique index on an expression calls a function QUAACK " \
                                                  "can't trust",
                     "unsupported_type" => "a column has a type QUAACK can't fill",
                     "domain_check" => "a column's domain rejects every value QUAACK tried" }.freeze

        # Where a rule_bugs entry's rewrite was proved wrong.
        BUG_STEPS = { "rewrite-test" => "on made-up test data",
                      "counterexamples" => "on test data the LLM wrote to break it",
                      "result-comparison" => "on the real data" }.freeze

        # DESIGN.md's burndown's stages: the original query's index search.
        INDEX_STAGES = { "index-from-query" => "Ideas from the query's text",
                         "index-from-plan" => "Ideas from the query's plan",
                         "index-dedupe" => "Removing duplicates and indexes you already have",
                         "index-test" => "Asking the planner whether it would use each one",
                         "llm-index-ideas" => "Ideas from the LLM",
                         "llm-index-refine" => "The LLM's second round of ideas",
                         "index-rank" => "Trying indexes together" }.freeze

        # The rewrite stages that come before the rewrites' index searches,
        # and the ones that come after.
        REWRITE_STAGES = { "rewrite-rules" => "Rewrites from QUAACK's own rules",
                           "llm-rewrites" => "Rewrites from the LLM",
                           "operator-rewrites" => "Your own rewrites",
                           "assumption-check" => "Checking what each rewrite assumes",
                           "plan-pruning" => "Checking each rewrite can run differently from your query",
                           "rewrite-test" => "Testing on made-up edge-case data",
                           "counterexamples" => "Testing on data the LLM wrote to break them" }.freeze
        LATE_STAGES = { "rewrite-index-ideas" => "Choosing indexes for each rewrite",
                        "measurement" => "Measuring on the real data and choosing" }.freeze

        # A stage record's added, dropped, and extra names.
        COUNTS = { "generator_one" => "from the query's text", "generator_two" => "from the query's plan",
                   "llm" => "from the LLM", "operator" => "from you",
                   "duplicate" => "the same as another idea",
                   "covered_by_existing" => "already covered by an index you have",
                   "partial_not_low_cardinality" => "partial indexes on a column with too many values",
                   "never_used" => "never used by the planner", "hypopg_refused" => "HypoPG couldn't create",
                   "over_cap" => "over the limit of ten", "failed_checks" => "failed QUAACK's checks",
                   "inbound_check" => "failed the checks on what goes in",
                   "failed_to_plan" => "didn't plan", "output_mismatch" => "returned different columns",
                   "same_plans" => "planned the same as your query",
                   "untested_atoms" => "conditions the test data never exercised",
                   "too_many" => "over the limit of five", "bad_assumption" => "assumed something QUAACK can't check",
                   "unmet_assumption" => "assumed something your data doesn't hold",
                   "operator_warnings" => "warnings on your own rewrites",
                   "vacuity_guard_retries" => "retries to make sure every condition mattered",
                   "atoms_covered" => "untested conditions the LLM's data exercised",
                   "production_mismatch" => "wrong on the real data",
                   "production_timed_out" => "timed out on the real data",
                   "production_not_compared" => "couldn't be compared on the real data",
                   "not_better" => "no better than your query", "footprint_tie" => "lost a tie on index size",
                   "below_top_three" => "outside the top three",
                   "measurement_timed_out" => "timed out in every measurement run",
                   "partial_comparisons" => "compared on only part of the real data",
                   **SCENARIOS.transform_values { "wrong on #{it}" },
                   **(1..3).to_h { ["round_#{it}", "wrong in round #{it}"] } }.freeze

        # What each of the driver's LLM calls was for.
        LLM_STEPS = { "llm-index-ideas" => "Index suggestions for the original query",
                      "llm-index-refine" => "Revised index suggestions for the original query",
                      "llm-rewrites" => "Rewrite suggestions", "operator-rewrites" => "Reading your own rewrites",
                      "llm-counterexamples" => "Test data written to break the rewrites",
                      "rewrite-llm-index-ideas" => "Index suggestions for the rewrites",
                      "rewrite-llm-index-refine" => "Revised index suggestions for the rewrites" }.freeze

        # DESIGN.md's burndown's work totals from the enclave, always listed.
        TOTALS = { "hypothetical_explains" => "Plans tried with an index that wasn't built",
                   "indexes_built" => "Indexes really built", "measurement_runs" => "Measurement runs",
                   "fixture_loads" => "Loads of made-up test data" }.freeze

        module_function

        # A name the report has no words for, as words: its underscores
        # become spaces.
        def plain(name) = name.to_s.tr("_", " ")

        def set(name) = SETS.fetch(name) { plain(name) }

        # "rewrite_3" as "Rewrite" and its name in the run, such as
        # "Rewrite Silver Fox" (RewriteNames). Anything else as it is.
        def rewrite(name, run_id) = RewriteNames.label(run_id, name)

        # "rewrite_3" as "Rewrite 3", for a rewrite with no name. Anything
        # else as it is.
        def numbered(name) = name.to_s.sub(/\Arewrite_(\d+)\z/, 'Rewrite \\1')

        # A search, mid-sentence: "your query" or "rewrite Silver Fox".
        def search(name, run_id) = name == "original" ? "your query" : lower(rewrite(name, run_id))

        def lower(text) = text.sub(/\A[A-Z]/, &:downcase)

        def upper(text) = text.sub(/\A[a-z]/, &:upcase)

        # "1 call", "2 calls".
        def count(number, one, many = "#{one}s") = "#{Format.number(number)} #{number == 1 ? one : many}"
      end
    end
  end
end
