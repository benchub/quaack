# frozen_string_literal: true

module Quaack
  module Enclave
    # README 5a-6: which of the LLM's 5a-5 candidates fell short in 5a-4.
    #
    #   Refinement.shortfalls(entry)
    #   # => [nil, ["unused", nil], ["beaten", 2], ...]
    #
    # entry is an index_search_<search> store entry (see Steps::IndexSearch
    # and Steps::IndexTest). There's one element per first-round LLM result,
    # in order: the revisions 5a-6 itself tested (tagged "round" =>
    # "refinement") are left out. Each is nil if the candidate held up, or:
    # - ["unused", nil] if HypoPG refused it or the planner used it for no
    #   literal set.
    # - ["beaten", i] if mechanical result i (0-based in "results") is
    #   simpler and did no worse: it has fewer key and INCLUDE columns, or as
    #   many and a smaller estimated size, and its worst-case cost across
    #   the literal sets is no higher. Only mechanical results the planner
    #   used count. i is the simplest such result.
    module Refinement
      module_function

      def first_round(entry) = (entry["llm_results"] || []).reject { it["round"] == "refinement" }

      def shortfalls(entry)
        mechanical = entry["results"].each_with_index.select { |result, _| used?(result) }
        first_round(entry).map do |result|
          next ["unused", nil] unless used?(result)

          index = beaten_by(result, mechanical)
          ["beaten", index] if index
        end
      end

      # The index of the simplest used mechanical result that beat result, or nil.
      def beaten_by(result, mechanical)
        beaten = mechanical.select { |other, _| simpler?(other, result) && worst(other) <= worst(result) }
        beaten.min_by { |other, _| simplicity(other) }&.last
      end

      def used?(result) = !result["refusal"] && result["plans"].values.any? { it["used"] }

      def worst(result) = result["plans"].values.map { it["total_cost"] }.max

      def simplicity(result)
        [result["candidate"]["key"].size + result["candidate"]["include"].size, result["size"]]
      end

      def simpler?(one, other) = (simplicity(one) <=> simplicity(other)).negative?
    end
  end
end
