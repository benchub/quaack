# frozen_string_literal: true

require "quaack/protocol/step_counts"

module Quaack
  module Driver
    # StepSummary's summaries for the enclave steps that send a step_counts
    # message (see Protocol::StepCounts), from the step's reply:
    #
    #   CountedSummary.searched(reply)  # => "Found 12 possible indexes mechanically, 3 used by the planner"
    #
    # Trust boundary. The driver takes a step_counts only if it passes
    # Protocol::StepCounts.valid?, so each count is a small Integer and each
    # rule name is on Protocol::StepCounts::RULE_NAMES. Without one that
    # passes, and that has every count the summary needs, the summary says
    # only what the step did.
    module CountedSummary
      module_function

      def count(...) = StepSummary.count(...)

      # The reply's step_counts fields, if it has one that passes
      # Protocol::StepCounts.valid?, else nil.
      def step_counts(reply)
        message = reply.messages.find { it["type"] == "step_counts" }
        fields = message&.except("type")
        fields if Protocol::StepCounts.valid?(fields)
      end

      # The reply's counts named, in order, or nil unless it has them all.
      def numbers(reply, *names)
        values = step_counts(reply)&.values_at(*names)
        values unless values.nil? || values.any?(&:nil?)
      end

      # The rules rewrite-rules' step_counts says fired, or none.
      def fired(reply) = step_counts(reply)&.fetch("rules", nil) || []

      # ", n timed out", or nothing for none.
      def timed_out(number) = number.zero? ? "" : ", #{number} timed out"

      # names as a list: a, a and b, a, b, and c.
      def listed(names) = names.size < 3 ? names.join(" and ") : "#{names[0..-2].join(", ")}, and #{names.last}"

      # A step's summary from the counts names: plain if they're missing,
      # none if the first is zero, else the block's line.
      def measured(reply, names, plain, none = plain)
        values = numbers(reply, *names)
        return plain if values.nil?
        return none if values.first.zero?

        yield(*values)
      end

      def searched(reply)
        measured(reply, %w[found used], "Searched for indexes", "Found no possible index mechanically") do |found, used|
          "Found #{count(found, "possible index", "possible indexes")} mechanically, #{used} used by the planner"
        end
      end

      def ranked(reply)
        measured(reply, %w[ranked combined], "Ranked the index ideas", "No index to rank") do |ranked, combined|
          "Ranked the top #{count(ranked, "index", "indexes")}" \
            "#{", and a combination of #{combined}" if combined.positive?}"
        end
      end

      def arena(reply)
        measured(reply, %w[tables], "Set up the arena") { "Set up the arena with #{count(it, "table")}" }
      end

      def baseline(reply)
        measured(reply, %w[sets timed_out], "Measured the original query") do |sets, out|
          "Measured the original query on #{count(sets, "literal set")}#{timed_out(out)}"
        end
      end

      def index_baseline(reply)
        measured(reply, %w[combinations timed_out], "Measured the original query with each set of indexes") do |n, out|
          "Measured the original query with #{count(n, "set of indexes", "sets of indexes")}#{timed_out(out)}"
        end
      end

      def candidate_runs(reply)
        measured(reply, %w[measured timed_out], "Measured each rewrite", "No rewrites to measure") do |runs, out|
          "Measured #{count(runs, "rewrite run")}#{timed_out(out)}"
        end
      end

      def minimax(reply)
        measured(reply, %w[compared survivors], "Checked each choice against the original on every literal",
                 "No choices to check against the original") do |compared, survivors|
          "Checked #{count(compared, "choice")} against the original on every literal, #{survivors} held up"
        end
      end

      def result_comparison(reply)
        measured(reply, %w[compared discarded partial], "Checked each rewrite's rows on production data",
                 "No rewrites to check on production data") do |compared, discarded, partial|
          "Checked the rows of #{count(compared, "rewrite")} on production data, #{discarded} differed" \
            "#{", #{count(partial, "check")} partial" unless partial.zero?}"
        end
      end

      def selection(reply)
        measured(reply, %w[top excluded], "Picked the top choices", "No choice beat the original") do |top, out|
          "Picked #{count(top, "top choice")}#{", #{out} left out" unless out.zero?}"
        end
      end
    end
  end
end
