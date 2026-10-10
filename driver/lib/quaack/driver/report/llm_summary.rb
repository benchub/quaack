# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the LLM-written summary that opens "Why the winner
      # reads fewer blocks" (DESIGN.md's report, WinnerSummary). The report
      # prints it under a label that says an LLM wrote it, who, and that the
      # measurements below are the facts. Everything it prints is escaped.
      module LLMSummary
        # What the label says besides who wrote it.
        SUMMARY_LABEL = "not measured. It compares the winner with the original query as it runs now, on the " \
                        "indexes your database already has. The measurements and plans below are the facts."

        # The summary as the template prints it: its text, and who wrote it as
        # HTML. nil when there's none, and the section reads as it does
        # without one.
        def llm_summary
          return unless @summary.is_a?(Hash) && @summary["text"].is_a?(String) && !@summary["text"].strip.empty?

          { text: @summary["text"], by: summary_by }
        end

        private

        # The entry's name and model, or just that an LLM wrote it when the
        # summary doesn't say which.
        def summary_by
          name, model = @summary.values_at("name", "model")
          return "an LLM" unless name.is_a?(String) && !name.empty?
          return h(name) unless model.is_a?(String) && !model.empty?

          "#{h("#{name}, ")}<code>#{h(model)}</code>"
        end
      end
    end
  end
end
