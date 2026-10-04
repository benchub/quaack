# frozen_string_literal: true

module Quaack
  module Driver
    # What each step of `quaack run` did, for its closing progress line,
    # from the step's result (see Pipeline.step):
    #
    #   StepSummary::SUMMARY.fetch("index-build").call(5)  # => "Built 5 indexes"
    #
    # Trust boundary. Each is built only from counts and QUAACK's own words,
    # never from text in the result, which can come from the enclave or the
    # LLM. The report's path is the operator's own --out. The driver has no
    # list of rewrite-rules's rule names, and rewrite-rules sends none, so rewrite-rules's says
    # only how many rewrites the rules made. Sub-steps print no closing
    # line, so they have none.
    module StepSummary
      module_function

      # n and the noun, singular or plural: 1 rewrite, 3 rewrites.
      def count(number, one, many = "#{one}s") = "#{number} #{number == 1 ? one : many}"

      # How many of an enclave step's outcome messages are accepted.
      def kept(outcomes) = outcomes.count { it["outcome"] == "accepted" }

      # What an LLM's index ideas came to: how many, how many the enclave
      # tested as new, and how many it set aside untested (GIN and GiST).
      def ideas(ddls, outcomes, kind = "index idea")
        return "Got no #{kind}s from the LLM" if ddls.empty?

        aside = outcomes.count { it["outcome"] == "set_aside" }
        got = "Got #{count(ddls.size, kind)} from the LLM, #{kept(outcomes)} of them new"
        aside.zero? ? got : "#{got} and tested, #{aside} set aside untested"
      end

      # rewrite-rules's, from rewrite-rules' reply.
      def rules(reply)
        outcomes = reply.messages.select { it["type"] == "rewrite_outcome" }
        return "No rule applied" if outcomes.empty?

        "QUAACK's rules made #{count(outcomes.size, "rewrite")}, #{kept(outcomes)} kept"
      end

      # llm-rewrites's, from RewriteGeneration's result.
      def rewrites(result)
        return "Got no rewrites from the LLM" if result.rewrites.empty?

        "Got #{count(result.rewrites.size, "rewrite")} from the LLM, #{kept(result.outcomes)} kept"
      end

      # operator-rewrites's, from OperatorCandidates' result.
      def operator(result)
        return "You gave no rewrites to check" if result.rewrites.empty?

        "Checked your #{count(result.rewrites.size, "rewrite")}, #{kept(result.outcomes)} kept"
      end

      # rewrite-correctness's, from whether each rewrite tested passed.
      def tested(passed)
        return "No rewrites left to test" if passed.empty?

        "Tested #{count(passed.size, "rewrite")}, #{passed.count(true)} passed"
      end

      # A step that went through each rewrite, from whether it did anything
      # for each, rather than finding it all already done on a resumed run.
      def per_rewrite(ran, did, none)
        return none if ran.empty?

        done = ran.count(false)
        return "#{count(done, "rewrite")} already done" if done == ran.size

        "#{did} #{count(ran.count(true), "rewrite")}#{", #{done} already done" unless done.zero?}"
      end

      # llm-index-refine's, from RefinementRound's result, or what Pipeline says it
      # skipped.
      def refined(result)
        return "No index ideas needed improving" if result.nil?
        return "Already improved the index ideas" if result == :refined

        ideas(result.ddls, result.outcomes, "revised index idea")
      end

      SUMMARY = {
        "index-search" => ->(_) { "Searched for indexes" },
        "llm-index-ideas" => ->(result) { ideas(result.rounds.flat_map(&:ddls), result.rounds.flat_map(&:outcomes)) },
        "llm-index-refine" => ->(result) { refined(result) },
        "index-rank" => ->(_) { "Ranked the index ideas" },
        "rewrite-rules" => ->(reply) { rules(reply) },
        "llm-rewrites" => ->(result) { rewrites(result) },
        "operator-rewrites" => ->(result) { operator(result) },
        "plan-pruning" => ->(ran) { per_rewrite(ran, "Searched for indexes for", "No rewrites to search") },
        "arena-setup" => ->(_) { "Set up the arena" },
        "rewrite-correctness" => ->(passed) { tested(passed) },
        "rewrite-index-ideas" => lambda { |ran|
          per_rewrite(ran, "Asked for index ideas for", "No rewrites needed index ideas")
        },
        "index-build" => ->(n) { n.zero? ? "No index to build" : "Built #{count(n, "index", "indexes")}" },
        "baseline" => ->(_) { "Measured the original query" },
        "index-baseline" => ->(_) { "Measured the original query with each set of indexes" },
        "candidate-runs" => ->(_) { "Measured each rewrite" },
        "minimax" => ->(_) { "Checked each choice against the original on every literal" },
        "result-comparison" => ->(_) { "Checked each rewrite's rows on production data" },
        "selection" => ->(_) { "Picked the top choices" },
        "report" => ->(path) { "Wrote the report to #{path}" }
      }.freeze
    end
  end
end
