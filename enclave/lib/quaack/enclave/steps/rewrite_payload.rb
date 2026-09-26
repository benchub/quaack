# frozen_string_literal: true

require_relative "index_payload"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-payload --run <run ID>` (README 6a): sends the
      # shape-only payload the driver gives the LLM when it asks for
      # rewrites, as one rewrite_payload message. It doesn't connect to
      # anything. Its fields are index_payload's (see IndexPayload), less
      # mechanical_results: query, placeholders, plan, schema, and stats.
      module RewritePayload
        module_function

        def call(store:, **)
          [{ type: :rewrite_payload, query: store.read("redacted_query"),
             placeholders: IndexPayload.placeholders(store),
             plan: store.read("redacted_plan")["explain"].map { it.except("Settings") },
             schema: IndexPayload.schema(store),
             stats: store.read("classification")["outbound_statistics"] }]
        end
      end
    end
  end
end
