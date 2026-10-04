# frozen_string_literal: true

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

        # Step 9's scenarios, by the test data each one loads.
        SCENARIOS = { "s0" => "empty tables", "s1" => "rows that just match and just miss", "s2" => "NULLs",
                      "s3" => "duplicate join keys", "s4" => "rows with no join partner",
                      "s5" => "extreme values", "s6" => "groups of one, many, and none" }.freeze

        # Why a test ended without comparing results. Any other rule is a
        # statement that failed on the test database.
        FAILURES = { "unsupported_order" => "the order of your query's rows can't be checked",
                     "statement_timeout" => "a statement timed out",
                     "statement_canceled" => "a statement was canceled" }.freeze
        FAILED = "a statement failed on the test database"

        # Why step 9 couldn't make up test data for the query, by its rule.
        REFUSALS = { "fk_cycle" => "its tables' foreign keys form a cycle QUAACK can't load",
                     "complex_check" => "a CHECK constraint on its tables is too complex for QUAACK to satisfy",
                     "unsatisfiable_check" => "no value QUAACK tried passes a CHECK constraint on its tables",
                     "expression_unique_index" => "a unique index on an expression calls a function QUAACK " \
                                                  "can't trust",
                     "unsupported_type" => "a column has a type QUAACK can't fill",
                     "domain_check" => "a column's domain rejects every value QUAACK tried" }.freeze

        # Where a rule_bugs entry's rewrite was proved wrong.
        BUG_STEPS = { "step9" => "on made-up test data", "step10" => "on test data the LLM wrote to break it",
                      "14c" => "on the real data" }.freeze

        # DESIGN.md 15b's stages: the original query's index search.
        INDEX_STAGES = { "5a-1" => "Ideas from the query's text", "5a-2" => "Ideas from the query's plan",
                         "5a-3" => "Removing duplicates and indexes you already have",
                         "5a-4" => "Asking the planner whether it would use each one",
                         "5a-5" => "Ideas from the LLM", "5a-6" => "The LLM's second round of ideas",
                         "5a-7" => "Trying indexes together" }.freeze

        # The rewrite stages that come before the rewrites' index searches,
        # and the ones that come after.
        REWRITE_STAGES = { "6c" => "Rewrites from QUAACK's own rules", "6a" => "Rewrites from the LLM",
                           "step7" => "Your own rewrites", "6b" => "Checking what each rewrite assumes",
                           "step8" => "Checking each rewrite can run differently from your query",
                           "step9" => "Testing on made-up edge-case data",
                           "step10" => "Testing on data the LLM wrote to break them" }.freeze
        LATE_STAGES = { "step11" => "Choosing indexes for each rewrite",
                        "step14" => "Measuring on the real data and choosing" }.freeze

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
                   **SCENARIOS.transform_values { "wrong on #{it}" } }.freeze

        # What each of the driver's LLM calls was for.
        LLM_STEPS = { "5a-5" => "Index suggestions for the original query",
                      "5a-6" => "Revised index suggestions for the original query",
                      "6a" => "Rewrite suggestions", "step7" => "Reading your own rewrites",
                      "10a" => "Test data written to break the rewrites",
                      "rewrite-llm-index-ideas" => "Index suggestions for the rewrites",
                      "rewrite-llm-index-refine" => "Revised index suggestions for the rewrites" }.freeze

        # DESIGN.md 15b's work totals from the enclave, always listed.
        TOTALS = { "hypothetical_explains" => "Plans tried with an index that wasn't built",
                   "indexes_built" => "Indexes really built", "measurement_runs" => "Measurement runs",
                   "fixture_loads" => "Loads of made-up test data" }.freeze

        module_function

        # A name the report has no words for, as words: its underscores
        # become spaces.
        def plain(name) = name.to_s.tr("_", " ")

        def set(name) = SETS.fetch(name) { plain(name) }

        # "rewrite_3" as "Rewrite 3". Anything else as it is.
        def rewrite(name) = name.to_s.sub(/\Arewrite_(\d+)\z/, 'Rewrite \1')

        # A search, mid-sentence: "your query" or "rewrite 3".
        def search(name) = name == "original" ? "your query" : lower(rewrite(name))

        def lower(text) = text.sub(/\A[A-Z]/, &:downcase)

        # "1 call", "2 calls".
        def count(number, one, many = "#{one}s") = "#{Format.number(number)} #{number == 1 ? one : many}"
      end
    end
  end
end
