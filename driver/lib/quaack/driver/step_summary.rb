# frozen_string_literal: true

require_relative "counted_summary"

module Quaack
  module Driver
    # What each step of `quaack run` did, for its closing progress line,
    # from the step's result (see Pipeline.step):
    #
    #   StepSummary::SUMMARY.fetch("index-build").call(5)  # => "Built 5 indexes"
    #
    # Trust boundary. Each is built only from counts and QUAACK's own words,
    # never from text in the result, which can come from the enclave or the
    # LLM. The report's path is the operator's own --out. The enclave steps
    # that print nothing else send a step_counts message, and rewrite-rules
    # names the rules that fired in one, which CountedSummary reads only
    # once it passes Protocol::StepCounts.valid?. Sub-steps print no
    # closing line, so they have none.
    module StepSummary
      module_function

      # call, an enclave call that runs under an LLM step's lines, such as
      # its index-test, with a note of its own under the step name first
      # each time, on progress, so the LLM's line isn't left open over it.
      def noting(progress, name, text, call)
        lambda do |*args, **options|
          progress.step_note(name, text)
          call.call(*args, **options)
        end
      end

      # As noting, for a call told whose work it's on, by:, the names of
      # the entries, which the router, client, words as a possessive, such
      # as "groq's" (LLM::Router#possessive): text holds %s where that
      # goes, "the LLM's" without them.
      def whose(progress, name, text, call, client)
        lambda do |*args, by: [], **options|
          progress.step_note(name, format(text, client.possessive(by)))
          call.call(*args, **options)
        end
      end

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

      # rewrite-rules', from rewrite-rules' reply, with the rules that fired
      # if its step_counts names them.
      def rules(reply)
        outcomes = reply.messages.select { it["type"] == "rewrite_outcome" }
        return "No rule applied" if outcomes.empty?

        names = CountedSummary.fired(reply)
        made = "QUAACK's rules made #{count(outcomes.size, "rewrite")}, #{kept(outcomes)} kept"
        names.empty? ? made : "#{made}, with #{CountedSummary.listed(names)}"
      end

      # llm-rewrites', from RewriteGeneration's result.
      def rewrites(result)
        return "Got no rewrites from the LLM" if result.rewrites.empty?

        "Got #{count(result.rewrites.size, "rewrite")} from the LLM, #{kept(result.outcomes)} kept"
      end

      # operator-rewrites', from OperatorCandidates' result.
      def operator(result)
        return "You gave no rewrites to check" if result.rewrites.empty?

        "Checked your #{count(result.rewrites.size, "rewrite")}, #{kept(result.outcomes)} kept"
      end

      # rewrite-correctness', from whether each rewrite tested passed.
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
        "index-search" => ->(reply) { CountedSummary.searched(reply) },
        "llm-index-ideas" => ->(result) { ideas(result.rounds.flat_map(&:ddls), result.rounds.flat_map(&:outcomes)) },
        "llm-index-refine" => ->(result) { refined(result) },
        "index-rank" => ->(reply) { CountedSummary.ranked(reply) },
        "rewrite-rules" => ->(reply) { rules(reply) },
        "llm-rewrites" => ->(result) { rewrites(result) },
        "operator-rewrites" => ->(result) { operator(result) },
        "plan-pruning" => ->(ran) { per_rewrite(ran, "Searched for indexes for", "No rewrites to search") },
        "arena-setup" => ->(reply) { CountedSummary.arena(reply) },
        "rewrite-correctness" => ->(passed) { tested(passed) },
        "rewrite-index-ideas" => lambda { |ran|
          per_rewrite(ran, "Asked for index ideas for", "No rewrites needed index ideas")
        },
        "index-build" => ->(n) { n.zero? ? "No index to build" : "Built #{count(n, "index", "indexes")}" },
        "baseline" => ->(reply) { CountedSummary.baseline(reply) },
        "index-baseline" => ->(reply) { CountedSummary.index_baseline(reply) },
        "candidate-runs" => ->(reply) { CountedSummary.candidate_runs(reply) },
        "minimax" => ->(reply) { CountedSummary.minimax(reply) },
        "result-comparison" => ->(reply) { CountedSummary.result_comparison(reply) },
        "selection" => ->(reply) { CountedSummary.selection(reply) },
        "report" => ->(path) { "Wrote the report to #{path}" }
      }.freeze

      # The steps whose summaries carry more than the step's own line, such
      # as counts or the report's path, so they close the step even on a
      # terminal (Progress#step's informative). The rest only say the step
      # is done, which there the clock already shows.
      INFORMATIVE = %w[index-search llm-index-ideas llm-index-refine index-rank rewrite-rules llm-rewrites
                       operator-rewrites plan-pruning arena-setup rewrite-correctness rewrite-index-ideas index-build
                       baseline index-baseline candidate-runs minimax result-comparison selection report].freeze
    end
  end
end
