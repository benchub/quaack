# frozen_string_literal: true

require "pg_query"
require_relative "index_payload"
require_relative "rewrite_source"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-payload --run <run ID>` (DESIGN.md's llm-rewrites): sends the
      # shape-only payload the driver gives the LLM when it asks for
      # rewrites, as one rewrite_payload message. It doesn't connect to
      # anything. Its fields are index_payload's (see IndexPayload), less
      # mechanical_results: query, placeholders, plan, schema, and stats,
      # plus rule_rewrites.
      #
      # rule_rewrites is [{ "sql", "rules" }], one per rule-made rewrite_<n>
      # (rewrite-rules), in order, so the LLM doesn't repeat them: its SQL,
      # with the original's $n placeholders, and its rule names, only those
      # of RewriteRules::RULES (RewriteSource.rules). Its transformation and
      # assumptions are never sent: a denormalized_equal assumption holds a
      # real type value.
      #
      # Trust boundary. The rules work on the redacted query, so a rule's SQL
      # holds no literal value. A rewrite is still sent only if every constant
      # in its parse is one the redacted query holds or one a rule writes
      # (RULE_CONSTANTS: the 1 of EXISTS (SELECT 1) or ORDER BY 1, and
      # true), so a store entry that somehow holds a real literal is left
      # out, not sent.
      module RewritePayload
        RULE_CONSTANTS = "SELECT 1 WHERE true"

        module_function

        def call(store:, **)
          [{ type: :rewrite_payload, query: store.read("redacted_query"),
             placeholders: IndexPayload.placeholders(store),
             plan: store.read("redacted_plan")["explain"].map { it.except("Settings") },
             schema: IndexPayload.schema(store),
             rule_rewrites: rule_rewrites(store),
             stats: IndexPayload.stats(store) }]
        end

        def rule_rewrites(store)
          allowed = constants(store.read("redacted_query")) | constants(RULE_CONSTANTS)
          rewrites(store).select { it["source"] == "rule" && sendable?(it["sql"], allowed) }
                         .map { { "sql" => it["sql"], "rules" => RewriteSource.rules(it) } }
        end

        # Every stored rewrite_<n>, in order.
        def rewrites(store)
          (1..).lazy.map { "rewrite_#{it}" }.take_while { store.entry?(it) }.map { store.read(it) }.to_a
        end

        def sendable?(sql, allowed)
          sql.is_a?(String) && (constants(sql) - allowed).empty?
        rescue PgQuery::ParseError
          false
        end

        # Every constant in sql's parse, without its location.
        def constants(sql)
          found = []
          PgQuery.parse(sql).walk! do |_parent, _field, node, _location|
            found << PgQuery::A_Const.encode(node.dup.tap { it.location = 0 }) if node.is_a?(PgQuery::A_Const)
          end
          found.uniq
        end
      end
    end
  end
end
