# frozen_string_literal: true

require_relative "../rewrite_rules"

module Quaack
  module Enclave
    module Steps
      # Where a stored rewrite came from, for ReportPayload, NegativeResult,
      # and RuleBugs (DESIGN.md 6c and step 15).
      #
      #   RewriteSource.fields(store.read("rewrite_1"))
      #   # => { "source" => "rule", "rules" => ["key_in_self_join"] }
      #
      # source is rule (6c), llm (6a), or operator (step 7), or nil for an
      # entry that holds none of them. rules is the names of the rules
      # applied, in order, for a rule-made rewrite, and nil for any other.
      #
      # Trust boundary. These go out in the report message unchecked, so only
      # QUAACK's own constants are sent, never what the entry holds as it
      # is: a source only if it's one of SOURCES, and a rule name only if
      # it's the name of one of RewriteRules::RULES. A rewrite's
      # transformation and assumptions are never read here.
      module RewriteSource
        SOURCES = %w[rule llm operator].freeze

        module_function

        def fields(entry)
          source = SOURCES.find { it == entry["source"] }
          { "source" => source, "rules" => (rules(entry) if source == "rule") }
        end

        def rules(entry)
          known = Enclave::RewriteRules::RULES.map(&:name)
          Array(entry["rules"]).filter_map { |name| known.find { it == name } }
        end
      end
    end
  end
end
