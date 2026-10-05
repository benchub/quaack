# frozen_string_literal: true

require_relative "../assumption_check"
require_relative "../burndown"
require_relative "../clock_anchoring"
require_relative "../literal_set"
require_relative "../rewrite_assumptions"
require_relative "../rewrite_burndown"
require_relative "../rewrite_candidate_check"
require_relative "../run_server"
require_relative "../structural_discard"
require_relative "../table_name"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-check --run <run ID>` (DESIGN.md's rewrite-check): checks rewrites and stores the survivors.
      #
      # stdin is one JSON object, {"rewrites": [{"sql", "transformation",
      # "assumptions"}, ...], "inferred": true|false}, "inferred" optional
      # and false by default: each rewrite's SQL with the original's $n
      # placeholders, its transformation as a String, and its assumptions as
      # an Array (see RewriteAssumptions). Any other shape is refused with
      # rewrite_check_bad_rewrites. For llm-rewrites' rewrites, only the first MAX
      # are checked; the rest are rejected as too_many. operator-rewrites' operator
      # rewrites come with "inferred": true: their transformation and
      # assumptions were inferred by the LLM, so they have no cap, and an
      # unmet assumption only adds a warning (DESIGN.md's operator-rewrites).
      #
      # On one racetrack connection, each rewrite goes through, in order: its assumptions' vocabulary (bad_assumption,
      # which a denormalized_equal from anything but a rewrite-rules rule is too), RewriteCandidateCheck (its rules),
      # assumption-check's AssumptionCheck (unmet_assumption), and structural-discard's StructuralDiscard, with the slow
      # literals (failed_to_plan, output_mismatch).
      #
      # The store format, which later steps read. Each survivor is saved as
      # rewrite_<n>, n counting up from 1 across calls in the run, as:
      #   "sql"            the candidate as RewriteCandidateCheck accepted it:
      #                    qualified, deparsed, with $n placeholders
      #   "transformation" the stated (or inferred) transformation, a String
      #   "assumptions"    the stated (or inferred) assumptions, as given
      #   "inferred"       false for llm-rewrites' rewrites, true for operator-rewrites'
      #   "warnings"       [{ "assumption", "kind" }], one per unmet inferred
      #                    assumption (operator-rewrites): its 1-based position in
      #                    "assumptions" and its kind; always [] for llm-rewrites
      #   "result_types"   its output column types, as regtype text
      #   "anchored_sql"   "sql" with its clock anchored as the original's
      #                    is (DESIGN.md's clock-anchor), with the same placeholder map and
      #                    column types; what later steps run, plan, and
      #                    bind (see RewriteEntry). "sql" keeps the clock as
      #                    written, for the payloads and the report. A
      #                    candidate ClockAnchoring refuses is rejected by
      #                    that error's rule.
      #   "source"         where it came from: "rule" (rewrite-rules), "llm" (llm-rewrites), or
      #                    "operator" (operator-rewrites)
      #   "rules"          only for a rule-made rewrite (rewrite-rules): the names of
      #                    the rules applied, in order
      # The transformation and assumptions come from the LLM (or, for rewrite-rules,
      # from the rules), so they're kept in the store only, never sent.
      #
      # A call records its counts in the burndown (RewriteBurndown.record_check), unless an earlier
      # call that died before its marker recorded them. A call with llm-rewrites' rewrites (not inferred) also writes
      # the rewrites_generated marker, so a resumed run skips llm-rewrites. A call
      # with operator-rewrites' (inferred) writes operator_rewrites_checked instead.
      #
      # It sends one rewrite_outcome per rewrite: index, outcome (accepted
      # or rejected), rule, rewrite (the entry name, or nil), and warnings.
      module RewriteCheck
        MAX = 5
        FIELDS = %w[assumptions sql transformation].freeze
        DATA_KINDS = %w[denormalized_equal].freeze

        class Error < IndexSearch::Error; end
        # A rewrite this step rejects by a rule of its own.
        class Rejected < IndexSearch::Error; end

        module_function

        def call(store:, input:, **)
          rewrites, inferred = rewrites(input)
          outcomes = check(store, source: inferred ? "operator" : "llm") { rewrites }
          store.write(inferred ? "operator_rewrites_checked" : "rewrites_generated", {})
          outcomes
        end

        # Checks the rewrites the block gives, stores the survivors, and
        # records the burndown (RewriteBurndown.record_check). It returns one rewrite_outcome per
        # rewrite. The block gets the racetrack connection every check runs
        # on. `quaacks rewrite-rules` (rewrite-rules) shares this, with source "rule".
        #
        # For source "rule", RewriteBurndown.check gives nothing: also is called with the
        # outcomes, and gives the burndown records, as Burndown.record_all
        # takes them. If it gives nil, nothing is recorded: that's how
        # rewrite-rules, run again, says an earlier call recorded them all.
        #
        # stored is { accepted SQL => entry name }, the rewrites an earlier
        # call already stored. A survivor whose accepted SQL is there keeps
        # that entry, and nothing new is written for it. That's how rewrite-rules, run
        # again after a call that died, stores no rewrite twice.
        def check(store, source:, stored: {}, also: ->(_) { [] })
          connection = Enclave::RunServer.connect(store, :racetrack)
          context = context(store, connection, source).merge(stored: stored.dup)
          tagged = yield(connection).each_with_index.map { |rewrite, i| outcome(i + 1, rewrite, context) }
          RewriteBurndown.record_check(store, source, tagged, also)
          tagged.map(&:first)
        ensure
          connection&.close
        end

        # What every rewrite of a call is checked with.
        def context(store, connection, source)
          { store:, connection:, source:, inferred: source == "operator", original: original(store),
            settings: store.read("plan")[0]["Settings"], **structure(store, connection) }
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

        # What StructuralDiscard compares each rewrite with: the original's
        # parameter type OIDs (each typed as its literal was), its output
        # type OIDs, and the slow literals.
        def structure(store, connection)
          original = store.read("redacted_query")
          param_types = StructuralDiscard.parameter_types(connection, original, IndexSearch.types(store, original))
          expected = param_types && StructuralDiscard.output_types(connection, original, param_types:)
          raise StructuralDiscard::Error, "the original query doesn't describe on the racetrack" unless expected

          { expected:, param_types:, literals: IndexSearch.values(LiteralSet.load(store).sets).fetch("slow") }
        end

        def original(store)
          relations = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          RewriteCandidateCheck::Original.new(relations:, placeholders: store.read("placeholder_shapes").size)
        end

        def outcome(index, rewrite, context)
          sql, types, warnings = checked(index, rewrite, context)
          name = context[:stored].delete(sql) || save(context, rewrite, sql, types, warnings)
          [{ type: :rewrite_outcome, index:, outcome: :accepted, rule: nil, rewrite: name, warnings: }, nil]
        rescue RewriteCandidateCheck::Error, ClockAnchoring::Error, Rejected => e
          [rejected(index, e.rule), RewriteBurndown.stage(e)]
        end

        # Raises Rejected if a rule of this step's own refuses the rewrite on arrival.
        def refuse!(index, rewrite, source)
          raise Rejected, "too_many" if index > MAX && source == "llm"
          raise Rejected, "bad_assumption" unless assumptions?(rewrite["assumptions"], source)
        end

        # Whether the assumptions are in assumption-check's vocabulary, with
        # denormalized_equal, which assumption-check checks against the data, only from a
        # rewrite-rules rule (DATA_KINDS). From anyone else it's refused here, before
        # anything is checked, so the LLM or the operator can't make assumption-check
        # probe the tables it names.
        def assumptions?(assumptions, source)
          RewriteAssumptions.valid?(assumptions) &&
            (source == "rule" || assumptions.none? { DATA_KINDS.include?(it["kind"]) })
        end

        # The accepted SQL, its output column types, and its warnings, or raises.
        def checked(index, rewrite, context)
          refuse!(index, rewrite, context[:source])
          connection = context[:connection]
          accepted = RewriteCandidateCheck.check(rewrite["sql"], context[:original], context[:settings], connection)
          warnings = unmet(rewrite["assumptions"], connection)
          raise Rejected, "unmet_assumption" unless warnings.empty? || context[:inferred]

          [accepted.sql, structural!(accepted.sql, context), warnings]
        end

        # The rewrite's output types as regtype text (they match the
        # original's), or raises Rejected with StructuralDiscard's reason.
        def structural!(sql, context)
          connection = context[:connection]
          reason = StructuralDiscard.reason(connection, sql, context[:literals], context[:expected],
                                            param_types: context[:param_types])
          raise Rejected, reason.to_s if reason

          oids = context[:expected].map { Integer(it) }
          connection.exec_params("SELECT unnest($1::oid[])::regtype::text", ["{#{oids.join(",")}}"]).column_values(0)
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
                            "result_types" => types, "anchored_sql" => anchored(sql, context),
                            "source" => context[:source], **rewrite.slice("rules"))
          name
        end

        # sql anchored as the original is (DESIGN.md's clock-anchor), or raises
        # ClockAnchoring::Error.
        def anchored(sql, context)
          store = context[:store]
          ClockAnchoring.anchor(sql, context[:settings], placeholder_map: store.read("placeholder_map"),
                                                         statistics: store.read("statistics")).sql
        end
      end
    end
  end
end
