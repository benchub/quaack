# frozen_string_literal: true

module Quaack
  module Driver
    # What each step of `quaack run` did, for its closing progress line,
    # from the step's result (see Pipeline.step):
    #
    #   StepSummary::SUMMARY.fetch("12a").call(5)  # => "Built 5 indexes"
    #
    # Trust boundary. Each is built only from counts and QUAACK's own words,
    # never from text in the result, which can come from the enclave or the
    # LLM. The report's path is the operator's own --out. The driver has no
    # list of 6c's rule names, and rewrite-rules sends none, so 6c's says
    # only how many rewrites the rules made. Sub-steps print no closing
    # line, so they have none.
    module StepSummary
      module_function

      # n and the noun, singular or plural: 1 rewrite, 3 rewrites.
      def count(number, one, many = "#{one}s") = "#{number} #{number == 1 ? one : many}"

      # How many of an enclave step's outcome messages are accepted.
      def kept(outcomes) = outcomes.count { it["outcome"] == "accepted" }

      # What an LLM's index ideas came to: how many, and how many the
      # enclave didn't drop.
      def ideas(ddls, outcomes, kind = "index idea")
        return "Got no #{kind}s from the LLM" if ddls.empty?

        "Got #{count(ddls.size, kind)} from the LLM, #{outcomes.count { it["outcome"] != "dropped" }} of them new"
      end

      # 6c's, from rewrite-rules' reply.
      def rules(reply)
        outcomes = reply.messages.select { it["type"] == "rewrite_outcome" }
        return "No rule applied" if outcomes.empty?

        "QUAACK's rules made #{count(outcomes.size, "rewrite")}, #{kept(outcomes)} kept"
      end

      # 6a's, from RewriteGeneration's result.
      def rewrites(result)
        return "Got no rewrites from the LLM" if result.rewrites.empty?

        "Got #{count(result.rewrites.size, "rewrite")} from the LLM, #{kept(result.outcomes)} kept"
      end

      # Step 7's, from OperatorCandidates' result.
      def operator(result) = "Checked your #{count(result.rewrites.size, "rewrite")}, #{kept(result.outcomes)} kept"

      # Steps 9-10's, from whether each rewrite tested passed.
      def tested(passed)
        return "No rewrites left to test" if passed.empty?

        "Tested #{count(passed.size, "rewrite")}, #{passed.count(true)} passed"
      end

      # A step that worked on n rewrites, or says none if there were none.
      def per_rewrite(number, did, none) = number.zero? ? none : "#{did} #{count(number, "rewrite")}"

      SUMMARY = {
        "index-search" => ->(_) { "Searched for indexes" },
        "5a-5" => ->(result) { ideas(result.rounds.flat_map(&:ddls), result.rounds.flat_map(&:outcomes)) },
        "5a-6" => lambda do |result|
          result ? ideas(result.ddls, result.outcomes, "revised index idea") : "No index ideas left to improve"
        end,
        "5a-7" => ->(_) { "Ranked the index ideas" },
        "6c" => ->(reply) { rules(reply) },
        "6a" => ->(result) { rewrites(result) },
        "step 7" => ->(result) { operator(result) },
        "step 8" => ->(n) { per_rewrite(n, "Searched for indexes for", "No rewrites to search") },
        "4b" => ->(_) { "Set up the arena" },
        "steps 9-10" => ->(passed) { tested(passed) },
        "step 11" => ->(n) { per_rewrite(n, "Asked for index ideas for", "No rewrites needed index ideas") },
        "12a" => ->(n) { n.zero? ? "No index to build" : "Built #{count(n, "index", "indexes")}" },
        "13" => ->(_) { "Measured the original query" },
        "13a" => ->(_) { "Measured the original query with each set of indexes" },
        "14" => ->(_) { "Measured each rewrite" },
        "14b" => ->(_) { "Checked each choice against the original on every literal" },
        "14c" => ->(_) { "Checked each rewrite's rows on production data" },
        "14d" => ->(_) { "Picked the top choices" },
        "15" => ->(path) { "Wrote the report to #{path}" }
      }.freeze
    end
  end
end
