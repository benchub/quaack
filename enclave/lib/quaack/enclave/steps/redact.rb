# frozen_string_literal: true

require "pg_query"
require_relative "../redaction"

module Quaack
  module Enclave
    module Steps
      # `quaacks redact --run <run ID>` (README 3g): redacts the run's query
      # and step 1 plan (see Redaction).
      #
      # It reads the run's qualified_query entry, which `quaacks qualify`
      # wrote, and plan. It doesn't touch production. It writes four
      # entries: placeholder_map, which holds the literals and never leaves;
      # placeholder_shapes; redacted_query, the SQL with $n in place of each
      # literal; and redacted_plan, {"explain", "masked", "dropped"}. The
      # 5a-5 payload step sends the last three. Everything is computed
      # before the first write, so a refusal stores nothing. The entries are
      # written one at a time, though, so a crash partway through the writes
      # can leave some stored. A rerun overwrites them all.
      #
      # It sends nothing itself. Its only line is DONE.
      module Redact
        module_function

        def call(store:, **)
          query = store.read("qualified_query")
          result = Redaction.redact(PgQuery.parse(query), store.read("plan"))
          plan = result.plan
          result.store(store)
          store.write("redacted_query", result.query.sql)
          store.write("redacted_plan", { "explain" => plan.explain, "masked" => plan.masked,
                                         "dropped" => plan.dropped })
          []
        end
      end
    end
  end
end
