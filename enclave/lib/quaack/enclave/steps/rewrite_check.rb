# frozen_string_literal: true

require_relative "../assumption_check"
require_relative "../rewrite_assumptions"
require_relative "../rewrite_candidate_check"
require_relative "../run_server"
require_relative "../structural_discard"
require_relative "../table_name"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-check --run <run ID>` (README 6a, 6b, and step 8's
      # structural discards): checks rewrites and stores the survivors.
      #
      # stdin is one JSON object, {"rewrites": [{"sql", "transformation",
      # "assumptions"}, ...], "inferred": true|false}, "inferred" optional
      # and false by default: each rewrite's SQL with the original's $n
      # placeholders, its transformation as a String, and its assumptions as
      # an Array (see RewriteAssumptions). Any other shape is refused with
      # rewrite_check_bad_rewrites. For 6a's rewrites, only the first MAX
      # are checked; the rest are rejected as too_many. Step 7's operator
      # rewrites come with "inferred": true: their transformation and
      # assumptions were inferred by the LLM, so they have no cap, and an
      # unmet assumption only adds a warning (README step 7).
      #
      # On one racetrack connection, each rewrite goes through, in order:
      # its assumptions' vocabulary (bad_assumption), RewriteCandidateCheck
      # (its rules), 6b's AssumptionCheck (unmet_assumption), and StructuralDiscard (plan_failed,
      # column_count_mismatch, column_type_mismatch).
      #
      # The store format, which later steps read. Each survivor is saved as
      # rewrite_<n>, n counting up from 1 across calls in the run, as:
      #   "sql"            the candidate as RewriteCandidateCheck accepted it:
      #                    qualified, deparsed, with $n placeholders
      #   "transformation" the stated (or inferred) transformation, a String
      #   "assumptions"    the stated (or inferred) assumptions, as given
      #   "inferred"       false for 6a's rewrites, true for step 7's
      #   "warnings"       [{ "assumption", "kind" }], one per unmet inferred
      #                    assumption (step 7): its 1-based position in
      #                    "assumptions" and its kind; always [] for 6a
      #   "result_types"   its output column types, as regtype text
      # The transformation and assumptions come from the LLM, so they're
      # kept in the store only, never sent.
      #
      # It sends one rewrite_outcome per rewrite: index, outcome (accepted
      # or rejected), rule, rewrite (the entry name, or nil), and warnings.
      module RewriteCheck
        MAX = 5
        FIELDS = %w[assumptions sql transformation].freeze

        class Error < IndexSearch::Error; end
        # A rewrite this step rejects by a rule of its own.
        class Rejected < IndexSearch::Error; end

        module_function

        def call(store:, input:, **)
          rewrites, inferred = rewrites(input)
          connection = Enclave::RunServer.connect(store, :racetrack)
          context = { store:, connection:, inferred:, original: original(store),
                      settings: store.read("plan")[0]["Settings"] }
          rewrites.each_with_index.map { |rewrite, i| outcome(i + 1, rewrite, context) }
        ensure
          connection&.close
        end

        def rewrites(input)
          inferred = input.fetch("inferred", false)
          list = input["rewrites"] if (input.keys - ["inferred"]) == ["rewrites"] && [true, false].include?(inferred)
          raise Error, "rewrite_check_bad_rewrites" unless list.is_a?(Array) && list.all? { rewrite?(it) }

          [list, inferred]
        end

        def rewrite?(rewrite)
          rewrite.is_a?(Hash) && rewrite.keys.sort == FIELDS && rewrite["sql"].is_a?(String) &&
            rewrite["transformation"].is_a?(String) && rewrite["assumptions"].is_a?(Array)
        end

        def original(store)
          relations = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          RewriteCandidateCheck::Original.new(relations:, placeholders: store.read("placeholder_shapes").size)
        end

        def outcome(index, rewrite, context)
          return rejected(index, "too_many") if index > MAX && !context[:inferred]
          return rejected(index, "bad_assumption") unless RewriteAssumptions.valid?(rewrite["assumptions"])

          sql, types, warnings = checked(rewrite, context)
          name = save(context, rewrite, sql, types, warnings)
          { type: :rewrite_outcome, index:, outcome: :accepted, rule: nil, rewrite: name, warnings: }
        rescue RewriteCandidateCheck::Error, StructuralDiscard::Error, Rejected => e
          rejected(index, e.rule)
        end

        # The accepted SQL, its output column types, and its warnings, or raises.
        def checked(rewrite, context)
          connection = context[:connection]
          accepted = RewriteCandidateCheck.check(rewrite["sql"], context[:original], context[:settings], connection)
          warnings = unmet(rewrite["assumptions"], connection)
          raise Rejected, "unmet_assumption" unless warnings.empty? || context[:inferred]

          [accepted.sql, StructuralDiscard.check(accepted.sql, context[:store].read("redacted_query"), connection),
           warnings]
        end

        def unmet(assumptions, connection)
          assumptions.each_with_index.reject { |assumption, _| AssumptionCheck.met?(assumption, connection) }
                     .map { |assumption, i| { "assumption" => i + 1, "kind" => assumption["kind"] } }
        end

        def rejected(index, rule)
          { type: :rewrite_outcome, index:, outcome: :rejected, rule:, rewrite: nil, warnings: [] }
        end

        def save(context, rewrite, sql, types, warnings)
          store = context[:store]
          name = (1..).lazy.map { "rewrite_#{it}" }.find { !store.entry?(it) }
          store.write(name, "sql" => sql, "transformation" => rewrite["transformation"],
                            "assumptions" => rewrite["assumptions"], "inferred" => context[:inferred],
                            "warnings" => warnings,
                            "result_types" => types)
          name
        end
      end
    end
  end
end
