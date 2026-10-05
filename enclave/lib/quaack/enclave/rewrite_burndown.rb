# frozen_string_literal: true

require "quaack/protocol/burndown"
require_relative "burndown"
require_relative "rewrite_candidate_check"

module Quaack
  module Enclave
    # DESIGN.md's burndown's rewrite stages, as Burndown records: only counts and QUAACK's own rule names.
    #
    # check gives the records of a rewrite-check call with llm-rewrites' or
    # operator-rewrites' rewrites, each under the search rewrites, from its
    # [outcome, stage] pairs, where stage says which stage rejected the
    # rewrite (nil when it was accepted). Each rewrite is dropped in one stage:
    #   llm-rewrites or     added { llm: or operator: every rewrite given },
    #   operator-rewrites   and dropped those refused on arrival (too_many,
    #                       bad_assumption, and RewriteCandidateCheck's
    #                       rules), by rule
    #   assumption-check    dropped unmet_assumption, with extra
    #                       operator_warnings: the warnings on the
    #                       operator's accepted rewrites
    #   plan-pruning        in and dropped StructuralDiscard's and
    #                       ClockAnchoring's rejections, by rule; out is 0,
    #                       since those that go on enter plan-pruning in
    #                       rewrite-prune
    # The rules are all code constants. One that isn't a burndown name is
    # counted as inbound_check or failed_checks.
    module RewriteBurndown
      ARRIVAL = { "llm" => "llm-rewrites", "operator" => "operator-rewrites" }.freeze
      # The stage each of RewriteCheck's own rules rejects in.
      OWN = { "too_many" => :arrival, "bad_assumption" => :arrival, "unmet_assumption" => :assumption }.freeze

      module_function

      # Records a rewrite-check call's burndown, check's records, once. For
      # source "rule", also gives the records instead (RewriteCheck.check).
      def record_check(store, source, tagged, also)
        return Burndown.record_once(store, check(source, tagged)) unless source == "rule"

        more = also.call(tagged.map(&:first))
        Burndown.record_all(store, more) if more
      end

      # The stage a RewriteCheck rejection, error, is counted in: RewriteCandidateCheck's rules on arrival,
      # RewriteCheck's own by OWN, and StructuralDiscard's and ClockAnchoring's in plan-pruning.
      def stage(error)
        return :arrival if error.is_a?(RewriteCandidateCheck::Error)

        OWN.fetch(error.rule, :pruning)
      end

      def check(source, tagged)
        arrival = by_rule(tagged, :arrival, :inbound_check)
        assumption = tagged.count { it[1] == :assumption }
        pruning = by_rule(tagged, :pruning, :failed_checks)
        arrived = tagged.size - arrival.values.sum
        [[ARRIVAL.fetch(source), :rewrites, { in: 0, added: { source.to_sym => tagged.size }, dropped: arrival,
                                              out: arrived }],
         ["assumption-check", :rewrites, { in: arrived, dropped: { unmet_assumption: assumption },
                                           out: arrived - assumption, extra: warnings(source, tagged) }],
         ["plan-pruning", :rewrites, { in: pruning.values.sum, dropped: pruning, out: 0 }]]
      end

      def by_rule(tagged, stage, fallback)
        tagged.select { it[1] == stage }.map { name(it[0][:rule], fallback) }.tally
      end

      def name(rule, fallback)
        Protocol::Burndown::NAME.match?(rule.to_s) ? rule.to_s.to_sym : fallback
      end

      def warnings(source, tagged)
        return {} unless source == "operator"

        { operator_warnings: tagged.sum { |outcome, _| outcome[:warnings].size } }
      end
    end
  end
end
