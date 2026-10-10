# frozen_string_literal: true

require "quaack/protocol/step_counts"
require_relative "format"
require_relative "rewrites"
require_relative "words"

module Quaack
  module Driver
    module Report
      # Mixed into View beside Rewrites, whose source it uses. Where a
      # rewrite came from, as HTML, with each of QUAACK's rules
      # linked to its page in docs/transforms (DESIGN.md's rewrite-rules):
      #
      #   source_html("source" => "rule", "rules" => ["key_in_self_join"])
      #   # => %(transform rule <a href=".../key_in_self_join.md">key_in_self_join</a>)
      #
      # Trust boundary. A name links only if it's on
      # Protocol::StepCounts::RULE_NAMES, and the URL is built from the
      # list's own String, never from the payload's. Everything else is
      # escaped, as h escapes it.
      module RuleLinks
        PAGES = "https://github.com/benchub/quaack/blob/main/docs/transforms/"

        # Rewrites#source, escaped, with its rules linked, or Words::MISSING
        # if the payload doesn't say.
        def source_html(entry)
          return llm_source_html(entry) if entry["source"] == "llm"

          return Format.h(source(entry) || Words::MISSING) unless entry["source"] == "rule"

          rules_html(Array(entry["rules"]))
        end

        def rules_html(rules)
          return "transform rules" if rules.empty?

          "transform #{rules.size == 1 ? "rule" : "rules"} #{rules.map { rule_link(it) }.join(", then ")}"
        end

        # A rule's name, escaped, and linked to its page, in a new tab, if
        # it's one of QUAACK's.
        def rule_link(name)
          known = Protocol::StepCounts::RULE_NAMES.find { it == name }
          return Format.h(name) unless known

          %(<a href="#{Format.h("#{PAGES}#{known}.md")}" target="_blank" rel="noopener">#{Format.h(known)}</a>)
        end
      end
    end
  end
end
