# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../castless_index"
require_relative "../index_store"
require_relative "existing_indexes"

module Quaack
  module Enclave
    module Steps
      # DESIGN.md's negative-result, for ReportPayload's negative field, whether or not the selection is
      # empty: which index candidates index-test found the planner never used or
      # HypoPG refused, and which index-dedupe's Dedupe dropped as covered by an
      # existing index. What became of each rewrite is in ReportPayload's
      # rewrites field (RewriteFate), whether or not the selection is empty.
      #
      #   NegativeResult.call(store)
      #   # => { "declined" => [{ "ddl", "reason", "sqlstate", "searches" }],
      #   #      "existing" => [{ "ddl", "covered_by" => { "name", "size_bytes", "definition" }, "searches" }] }
      #
      # Each index is sent once, with the searches it came up in (original,
      # rewrite_<n>), in the order they ran. A rewrite's search repeats most
      # of the original's candidates, the LLM proposes ones the generators
      # already made, and a plan prints a partial index's predicate with
      # casts the query's text doesn't have. So two candidates are one
      # index here when CastlessIndex.key says so, not when their DDL text
      # is the same, and the DDL sent is the first one's. A declined index
      # that was declined for two different reasons is sent once for each.
      #
      # Trust boundary. Search names, the reasons unused, hypopg_refused, and
      # unrenderable (REASONS; any other stored rule goes out as nil),
      # SQLSTATEs, existing index names (schema) and sizes
      # (ExistingIndexes), and DDL, each existing index's definition
      # included, through CandidateDdlRedaction. Never a
      # plan or a literal. Before call returns, every DDL string is checked
      # again (verify!, CandidateDdlRedaction#redacted?), and a literal
      # that isn't an MCV value of its own column fails the step with a
      # fixed message that names none.
      module NegativeResult
        # The negative result holds a DDL string that isn't in redacted form.
        class Error < StandardError; end

        SQLSTATE = /\A[0-9A-Z]{5}\z/

        # Why index-test declined a candidate: the planner never used it, or the
        # refusal rule SingleCandidateTest stores.
        REASONS = %w[unused hypopg_refused unrenderable].freeze

        module_function

        # redaction is the one that makes each DDL; every DDL string that
        # comes out is then checked by it again (verify!).
        def call(store, redaction: CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"]))
          searches = ["original", *rewrites(store)].select { store.entry?("index_search_#{it}") }
          sizes = ExistingIndexes.new(store)
          verify!({ "declined" => once(searches.flat_map { declined(store, it) }, redaction),
                    "existing" => once(searches.flat_map { existing(store, it, sizes, redaction) }, redaction) },
                  redaction)
        end

        # The check on the way out (20261009-50): negative is returned only
        # if each DDL string in it, a declined or existing index's ddl and
        # an existing index's covered_by definition (which may be nil), is
        # in redacted form by CandidateDdlRedaction#redacted?, the same
        # rules that mask it. Anything not shaped as call makes it fails
        # too. Fails closed, never quoting the DDL.
        def verify!(negative, redaction)
          raise Error, "a DDL string in this negative result isn't redacted" unless clean?(negative, redaction)

          negative
        end

        def clean?(negative, redaction)
          negative.is_a?(Hash) && %w[declined existing].all? do |key|
            list = negative[key]
            list.is_a?(Array) && list.all? { |entry| entry.is_a?(Hash) && entry_clean?(entry, redaction) }
          end
        end

        def entry_clean?(entry, redaction)
          covered = entry["covered_by"]
          return false unless redaction.redacted?(entry["ddl"])
          return true if covered.nil?

          covered.is_a?(Hash) && (covered["definition"].nil? || redaction.redacted?(covered["definition"]))
        end

        # Every stored rewrite_<n>, in number order, up to the first gap, as
        # candidate-runs and index-build read them. rewrite-check stores each
        # under the first free number and nothing deletes one, so a run has no gap.
        def rewrites(store) = (1..).lazy.map { "rewrite_#{it}" }.take_while { store.entry?(it) }.to_a

        # The entry's data, or nil if the run doesn't hold it.
        def optional(store, name) = (store.read(name) if store.entry?(name))

        # found is [candidate, search, fields] triples. One line for each
        # index and fields, in the order first seen, with its searches.
        def once(found, redaction)
          found.group_by { |candidate, _, fields| [CastlessIndex.key(candidate), fields] }.values.map do |group|
            candidate, _, fields = group.first
            { "ddl" => redaction.ddl(candidate), **fields, "searches" => group.map { it[1] }.uniq }
          end
        end

        def declined(store, search)
          entry = store.read("index_search_#{search}")
          set_aside = entry.fetch("set_aside", []).map { IndexStore.candidate(it) }
          [*entry["results"], *entry["llm_results"]].filter_map do |result|
            refusal = result["refusal"]
            next if refusal.nil? && kept?(result, set_aside)

            [IndexStore.candidate(result["candidate"]), search, refused(refusal)]
          end
        end

        def refused(refusal)
          { "reason" => REASONS.find { it == (refusal ? refusal["rule"] : "unused") },
            "sqlstate" => refusal && refusal["sqlstate"].to_s[SQLSTATE] }
        end

        # A tested candidate the planner used, or one set aside for index-build to
        # build for real (20260927-11). Neither was declined.
        def kept?(result, set_aside)
          result["plans"].values.any? { it["used"] } || set_aside.include?(IndexStore.candidate(result["candidate"]))
        end

        def existing(store, search, sizes, redaction)
          store.read("index_search_#{search}").dig("dedupe", "drops").to_a.filter_map do |drop|
            next unless drop["reason"] == "covered_by_existing"

            candidate = IndexStore.candidate(drop["candidate"])
            by = sizes.named(candidate.table, drop["covered_by"]["existing"])
            [candidate, search, { "covered_by" => by.merge("definition" => definition(drop["covered_by"], redaction)) }]
          end
        end

        # The existing index's definition, through the same redaction as the
        # candidate's DDL, so a partial index's predicate holds no literal.
        # nil if the stored drop has none.
        def definition(covered, redaction)
          redaction.ddl(IndexStore.candidate(covered["definition"])) if covered["definition"]
        end
      end
    end
  end
end
