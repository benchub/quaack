# frozen_string_literal: true

require_relative "dedupe"
require_relative "index_candidate"
require_relative "index_ddl_check"

module Quaack
  module Enclave
    # The enclave's half of README 5a-5: it takes the index DDL the LLM
    # wrote, through the driver, and filters it the way 5a-3 filters the
    # mechanical generators' output. The same call runs the replacement
    # round, and 5a-6's revision.
    #
    #   result = GeneratorThree.filter(ddls, dedupe:, tables:, settings:, connection:)
    #   result.survivors  # IndexCandidates for 5a-4, sources [:llm]
    #   GeneratorThree.messages(result)  # index_outcome messages, for egress
    #
    # ddls is an Array of Strings, one CREATE INDEX each, in the LLM's
    # order. dedupe is the search's Dedupe, holding the mechanical
    # generators' proposals, so an LLM candidate that repeats one is a
    # duplicate. tables, settings, and connection are IndexDdlCheck's.
    #
    # Each DDL, in order, gets an Outcome. index is its 1-based position.
    # status is:
    # - :dropped, with a rule: too_many past the first MAX_CANDIDATES (not
    #   even checked); any IndexDdlCheck rule, such as unqualified_table;
    #   unrepresentable when IndexCandidate.from_ddl can't hold what the
    #   check accepted, such as an operator class with parameters; or a
    #   Dedupe drop reason. covered_by is the existing index's name for
    #   covered_by_existing, and nil otherwise.
    # - :set_aside, for a GIN, GiST, or SP-GiST candidate HypoPG can't test.
    # - :accepted, for a survivor, which goes on to 5a-4.
    #
    # partial_constant_only is true for a partial candidate that wasn't
    # dropped (README 5a-5): it only works if the predicate's literal is a
    # constant in the application's SQL, not a bind parameter.
    #
    # Trust boundary. The DDL came from the LLM, which only saw shape, but a
    # partial predicate or key expression can still hold a value the LLM
    # guessed, so neither leaves: an Outcome's inspect shows its candidate
    # through IndexCandidate#inspect, which redacts both, and messages send
    # only the position, status, rule, covering index name (schema, so
    # shape), and tag. Every rule is one of the enclave's constants.
    module GeneratorThree
      # README 5a-5 asks for up to five.
      MAX_CANDIDATES = 5

      Outcome = Data.define(:index, :status, :rule, :covered_by, :partial_constant_only, :candidate)
      Result = Data.define(:outcomes, :survivors)

      module_function

      def filter(ddls, dedupe:, tables:, settings:, connection:)
        check_ddls(ddls)
        check = ->(sql) { IndexDdlCheck.check(sql, tables, settings, connection) }
        outcomes = ddls.each_with_index.map do |sql, i|
          next dropped(i + 1, "too_many") if i >= MAX_CANDIDATES

          outcome(i + 1, sql, dedupe, check)
        end
        Result.new(outcomes:, survivors: outcomes.select { it.status == :accepted }.map(&:candidate))
      end

      def check_ddls(ddls)
        return if ddls.is_a?(Array) && ddls.all?(String)

        raise ArgumentError, "ddls must be an Array of Strings"
      end

      def messages(result)
        result.outcomes.map do |o|
          { type: :index_outcome, index: o.index, outcome: o.status, rule: o.rule, covered_by: o.covered_by,
            partial_constant_only: o.partial_constant_only }
        end
      end

      def outcome(index, sql, dedupe, check)
        accepted = check.call(sql)
        candidate = IndexCandidate.from_ddl(accepted.sql, sources: [:llm])
        return dropped(index, "unrepresentable") unless candidate

        deduped(index, candidate, dedupe)
      rescue IndexDdlCheck::Error => e
        dropped(index, e.rule)
      end

      def deduped(index, candidate, dedupe)
        drops_before = dedupe.drops.size
        kept = dedupe.filter([candidate]).first
        return survived(index, :accepted, kept) if kept

        drop = dedupe.drops[drops_before]
        return survived(index, :set_aside, candidate) unless drop

        covered_by = drop.covered_by.name if drop.reason == :covered_by_existing
        dropped(index, drop.reason.name, covered_by:)
      end

      def survived(index, status, candidate)
        Outcome.new(index:, status:, rule: nil, covered_by: nil, partial_constant_only: !candidate.predicate.nil?,
                    candidate:)
      end

      def dropped(index, rule, covered_by: nil)
        Outcome.new(index:, status: :dropped, rule:, covered_by:, partial_constant_only: false, candidate: nil)
      end
    end
  end
end
