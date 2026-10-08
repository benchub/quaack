# frozen_string_literal: true

require_relative "providers"
require_relative "words"

module Quaack
  module Driver
    module Report
      # Mixed into View, after Providers: the fan-out branches the
      # provenance record says were dropped (DESIGN.md's "Several LLM
      # providers", Routing and Provenance, and report). Each is only a
      # step, an entry's name, and a rule, from the record as Providers
      # reads it, never a reason's words.
      module FailedBranches
        # Each dropped branch, as a sentence: "Rewrite suggestions: groq was
        # rate limited, so the step went on without it."
        def failed_branch_lines
          llm_record.fetch("failed_branches", []).map do |branch|
            "#{Words::LLM_STEPS.fetch(branch["step"])}: #{branch["entry"]} " \
              "#{Providers::ENDED.fetch(branch["rule"])}, so the step went on without it."
          end
        end
      end
    end
  end
end
