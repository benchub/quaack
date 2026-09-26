# frozen_string_literal: true

require "json"
require_relative "generator_three"

module Quaack
  module Driver
    # The driver's half of README 5a-6: one revision round for the LLM's
    # index candidates that fell short in 5a-4.
    #
    #   RefinementRound.new(client:, index_feedback:, index_test:).run(payload)
    #   # => nil (skipped) or Result(ddls: [...], outcomes: [...])
    #
    # index_feedback stands for `quaacks index-feedback` and returns its
    # index_feedback message. If it says nothing fell short (revise false),
    # or the round already ran (refined true), the round is skipped. Else
    # the LLM gets the 5a-5 payload and the feedback, and is asked for up to
    # as many revised candidates as fell short. index_test, as in
    # GeneratorThree but called with round: "refinement", filters and tests
    # them, even an empty list, which records that the round ran. Only one
    # round, with no replacement ask. payload may be a callable that
    # returns it, called only if the LLM is asked.
    #
    # Trust boundary. The prompt carries only the payload and the feedback,
    # both shape data the enclave built for leaving.
    class RefinementRound
      STEP = "5a-6"
      MAX_TOKENS = GeneratorThree::MAX_TOKENS

      SYSTEM = <<~PROMPT.freeze
        #{GeneratorThree::SYSTEM}
        This is a second look. You already proposed candidates, and each was tested with HypoPG. The feedback lists them with their redacted DDL, whether the planner used each one, its cost for each literal set next to the baseline cost with no index, its estimated size, its plan, and its shortfall: "unused" if the planner never used it, or "beaten" if the simpler mechanical candidate in beaten_by did at least as well. A partial predicate that doesn't match the query, an operator class that doesn't fit the column's collation, or an expression that doesn't match the query's exactly are the usual reasons. Propose revised candidates for the ones that fell short.
      PROMPT

      Result = Data.define(:ddls, :outcomes)

      def self.index_feedback(transport, run_id:, search: "original")
        lambda do
          transport.call("index-feedback", args: { run: run_id, search: })
                   .messages.find { it["type"] == "index_feedback" }
        end
      end

      def self.index_test(transport, run_id:, search: "original")
        lambda do |ddls, round:|
          transport.call("index-test", args: { run: run_id, search:, round: }, input: { "ddls" => ddls })
                   .messages.select { it["type"] == "index_outcome" }
        end
      end

      def initialize(client:, index_feedback:, index_test:)
        @client = client
        @index_feedback = index_feedback
        @index_test = index_test
      end

      def run(payload)
        feedback = @index_feedback.call
        return nil if !feedback["revise"] || feedback["refined"]

        ddls = ask(payload, feedback)
        Result.new(ddls:, outcomes: @index_test.call(ddls, round: "refinement"))
      end

      private

      def ask(payload, feedback)
        short = feedback["candidates"].count { it["shortfall"] }
        payload = payload.call if payload.respond_to?(:call)
        content = "The payload:\n\n```json\n#{JSON.generate(payload)}\n```\n\n" \
                  "Your candidates' results:\n\n```json\n#{JSON.generate(feedback["candidates"])}\n```\n\n" \
                  "Baseline cost per literal set: #{JSON.generate(feedback["baseline"])}\n\n" \
                  "Propose up to #{short} revised candidates. Answer with JSON: {\"indexes\": [...]}."
        @client.ask(step: STEP, system: SYSTEM, messages: [{ role: :user, content: }], max_tokens: MAX_TOKENS,
                    schema: GeneratorThree::SCHEMA).fetch("indexes")
      end
    end
  end
end
