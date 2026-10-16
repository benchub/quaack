# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The burndown's stage sentences, in plain words.
      module StageSentences
        # One plain sentence per stage, from DESIGN.md's description of it,
        # for the hover on a Sankey node and the tooltip on a table row.
        TABLE = {
          "index-from-query" => "QUAACK reads the original query and suggests indices for the tables, columns, " \
                                "and conditions it uses.",
          "index-from-plan" => "QUAACK suggests indices from the plan the database made for the original query.",
          "index-dedupe" => "QUAACK drops ideas that repeat another idea or that an index you already have covers.",
          "index-test" => "QUAACK asks the planner whether it would use each idea, and drops the ones it wouldn't.",
          "llm-index-ideas" => "The LLM suggests indices that QUAACK's own search missed.",
          "llm-index-refine" => "If any index idea fell short, the LLM gets one chance to revise it.",
          "index-rank" => "QUAACK tries the indices together, adding one at a time while the cost keeps " \
                          "dropping, up to three. It doesn't try every combination: it pairs the best single " \
                          "index with each of the others, then tries triples the same way, so n ideas take about " \
                          "n - 1 pairs and up to n - 2 triples.",
          "rewrite-rules" => "The transform rules rewrite the query, and QUAACK drops rewrites that fail its checks.",
          "llm-rewrites" => "The LLM suggests rewrites of the original query, and QUAACK drops any that fail " \
                            "its checks or go over the limit of five.",
          "operator-rewrites" => "QUAACK asks the LLM what each rewrite you wrote assumes, checks those assumptions " \
                                 "against the database, and warns about any it can't confirm.",
          "assumption-check" => "QUAACK checks each assumption a rewrite makes against the database's " \
                                "constraints and indices.",
          "plan-pruning" => "QUAACK plans each rewrite, and drops any that can't plan, return a different number or " \
                            "type of columns, or get the same plan as the original query, with or without indices.",
          "fuzz" => "QUAACK runs each rewrite and the original query on random small databases built around the " \
                    "query's own values, and drops any rewrite whose results differ.",
          "enumerate" => "QUAACK then runs each rewrite that's left and the original query on every database of " \
                         "up to a few rows over the query's own values, smallest first, for up to 30 seconds, and " \
                         "drops any rewrite whose results differ.",
          "rewrite-test" => "QUAACK runs each rewrite on made-up data built to show where it differs from " \
                            "the original query.",
          "counterexamples" => "The LLM writes data to try to break each rewrite that's left, for up to three rounds.",
          "rewrite-index-ideas" => "Each rewrite that's left gets its own index search, since it can need " \
                                   "different indices than the original query.",
          "measurement" => "QUAACK builds the indices, measures how many blocks each candidate reads on the real " \
                           "data, and chooses the best."
        }.freeze

        # What the rewrites' ranking adds to its sentence: its counts are every rewrite's, added up.
        SUMMED = "Each rewrite has its own search, and the counts here add up every rewrite's."

        # A stage's sentence, or nil for none. The rewrites' own index
        # searches run the index stages on a rewrite, so for those
        # (of_rewrite) it says "the rewrite" where the sentence says "the original query".
        def self.for(stage, of_rewrite: false)
          sentence = TABLE[stage]
          return sentence unless of_rewrite && sentence

          sentence = sentence.sub("the original query", "the rewrite")
          stage == "index-rank" ? "#{sentence} #{SUMMED}" : sentence
        end
      end
    end
  end
end
