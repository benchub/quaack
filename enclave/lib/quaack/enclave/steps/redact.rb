# frozen_string_literal: true

require "pg_query"
require_relative "../redaction"
require_relative "../inventory/production"

module Quaack
  module Enclave
    module Steps
      # `quaacks redact --run <run ID>` (DESIGN.md's redact): redacts the run's query
      # and input plan (see Redaction).
      #
      # It reads the run's qualified_query entry, which `quaacks qualify`
      # wrote, and plan. It doesn't touch production. It writes four
      # entries: placeholder_map, which holds the literals and never leaves;
      # placeholder_shapes; redacted_query, the SQL with $n in place of each
      # literal; and redacted_plan, {"explain", "masked", "dropped"}. The
      # llm-index-ideas payload step sends the last three. Everything is computed
      # before the first write, so a refusal stores nothing. The entries are
      # written one at a time, though, so a crash partway through the writes
      # can leave some stored. A rerun overwrites them all.
      #
      # It sends nothing itself. Its only line is DONE.
      module Redact
        module_function

        def call(store:, **)
          query = store.read("qualified_query")
          result = Redaction.redact(PgQuery.parse(query), store.read("plan"), printed: printed(store))
          plan = result.plan
          result.store(store)
          store.write("redacted_query", result.query.sql)
          store.write("redacted_plan", { "explain" => plan.explain, "masked" => plan.masked,
                                         "dropped" => plan.dropped })
          []
        end

        # How Postgres prints the string placeholders that read as dates or
        # times, asked of production in one read-only query, with
        # inventory's DateStyle, IntervalStyle, and TimeZone when the run
        # has them.
        def printed(store)
          production = Enclave::Inventory::Production
          settings = store.read("inventory")["settings"] if store.entry?("inventory")
          lambda do |map|
            Redaction.printed(map, settings:, connect: -> { production.connect(production.params(store)) },
                                   read_only: production.method(:read_only))
          end
        end
      end
    end
  end
end
