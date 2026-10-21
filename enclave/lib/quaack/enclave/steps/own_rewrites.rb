# frozen_string_literal: true

require "quaack/protocol/own_rewrites"
require_relative "rewrite_payload"

module Quaack
  module Enclave
    module Steps
      # report-payload's own_rewrites (task 20261021-2): rewrite-check's
      # own_rewrites entry, each of the operator's rewrites kept or not, or
      # nil for a run without one.
      #
      # Trust boundary. A field goes out only if it's QUAACK's own shape
      # (Protocol::OwnRewrites), or nil in its place. The text goes out only
      # if every constant in its parse is one the redacted query holds or one
      # a rule writes (RewritePayload.sendable?, the check rule-made rewrites
      # pass before they go to the LLM), so text that holds a real literal
      # goes out as nil.
      module OwnRewrites
        module_function

        def call(store)
          return unless store.entry?("own_rewrites")

          list = store.read("own_rewrites")
          return [] unless list.is_a?(Array)

          allowed = RewritePayload.constants(store.read("redacted_query")) |
                    RewritePayload.constants(RewritePayload::RULE_CONSTANTS)
          list.grep(Hash).map { entry(it, allowed) }
        end

        def entry(stored, allowed)
          sql = stored["sql"]
          fields = { "index" => (stored["index"] if stored["index"].is_a?(Integer)),
                     "sql" => (sql if RewritePayload.sendable?(sql, allowed)),
                     "outcome" => (stored["outcome"] if Protocol::OwnRewrites::OUTCOMES.include?(stored["outcome"])),
                     "rule" => (stored["rule"] if Protocol::RewriteBudget.rule?(stored["rule"])),
                     "rewrite" => (stored["rewrite"] if Protocol::OwnRewrites.name?(stored["rewrite"])) }
          fields.sort.to_h
        end
      end
    end
  end
end
