# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # The check on the record's winner_summary, how the report's
      # winner-summary ask ended: its outcome, one of OUTCOMES, the entry
      # that answered, if one did, and, for a failed ask, its rule. No other
      # key, so never the summary's text.
      module SummaryShape
        OUTCOMES = %w[used empty rejected failed].freeze
        KEYS = %w[outcome entry rule].freeze

        module_function

        # raw as the record keeps it, or nil if it isn't well formed.
        def check(raw)
          return unless raw.is_a?(Hash) && (raw.keys - KEYS).empty? && OUTCOMES.include?(raw["outcome"])
          return unless entry?(raw) && rule?(raw)

          raw.slice(*KEYS)
        end

        # Whether the entry, if given, is a name.
        def entry?(raw) = !raw.key?("entry") || NAME.match?(raw["entry"].to_s)

        # Whether the rule is there for a failed ask, and only then, and a rule.
        def rule?(raw)
          return false unless raw.key?("rule") == (raw["outcome"] == "failed")

          !raw.key?("rule") || RULE.match?(raw["rule"].to_s)
        end
      end
    end
  end
end
