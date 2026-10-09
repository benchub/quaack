# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The burndown's stage sentences, in plain words.
      module StageSentences
        # One plain sentence per stage, from DESIGN.md's description of it,
        # for the hover on a funnel band and the tooltip on a table row.
        TABLE = {
          "index-from-query" => "QUAACK reads the original query and suggests indexes for the tables, columns, " \
                                "and conditions it uses.",
          "index-from-plan" => "QUAACK suggests indexes from the plan the database made for the original query.",
          "index-dedupe" => "QUAACK drops ideas that repeat another idea or that an index you already have covers.",
          "index-test" => "QUAACK asks the planner whether it would use each idea, and drops the ones it wouldn't.",
          "llm-index-ideas" => "The LLM suggests indexes that QUAACK's own search missed.",
          "llm-index-refine" => "The LLM gets a second round to improve its index ideas.",
          "index-rank" => "QUAACK tries the indexes together, adding one at a time while the cost keeps " \
                          "dropping, up to three.",
          "rewrite-rules" => "QUAACK's own rules rewrite the query, and QUAACK drops repeats and rewrites " \
                             "that fail its checks.",
          "llm-rewrites" => "The LLM suggests rewrites of the original query, and QUAACK drops any that fail " \
                            "its checks or go over the limit of five.",
          "operator-rewrites" => "QUAACK checks the rewrites you wrote against its rules and against what " \
                                 "the LLM says they assume.",
          "assumption-check" => "QUAACK checks each assumption a rewrite makes against the database's " \
                                "constraints and indexes.",
          "plan-pruning" => "QUAACK plans each rewrite, and drops any that can't plan, return different " \
                            "columns, or plan the same as the original query.",
          "rewrite-test" => "QUAACK runs each rewrite on made-up data built to show where it differs from " \
                            "the original query.",
          "counterexamples" => "The LLM writes data to try to break each rewrite that's left, for up to three rounds.",
          "rewrite-index-ideas" => "Each rewrite that's left gets its own index search, since it can need " \
                                   "different indexes than the original query.",
          "measurement" => "QUAACK builds the indexes, measures how many blocks each candidate reads on the real " \
                           "data, and chooses the best."
        }.freeze

        # A stage's sentence, or nil for none. The rewrites' own index
        # searches run the index stages on a rewrite, so for those
        # (of_rewrite) it says "the rewrite" where the sentence says "the original query".
        def self.for(stage, of_rewrite: false)
          sentence = TABLE[stage]
          of_rewrite && sentence ? sentence.sub("the original query", "the rewrite") : sentence
        end
      end
    end
  end
end
