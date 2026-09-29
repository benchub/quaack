# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../relations"

module Quaack
  module Enclave
    module Steps
      # `quaacks qualify --run <run ID>` (DESIGN.md, steps 1 and 3a): fully
      # qualifies the run's query against its production server, and checks
      # that every relation it uses is a plain table (see Relations).
      #
      # It reads the run's query, plan, and server entries. It connects to
      # the server with the operator's libpq setup, as step 2 does
      # (Inventory::Production.connect), and resolves names through the
      # search_path in the plan's SETTINGS, or the default path without one.
      # Only the catalog is read, with plain SELECTs.
      #
      # It writes two entries, for the later steps of 3 to read:
      #
      # - qualified_query: the query's text with every relation naming its
      #   schema, a String. It holds the query's literals.
      # - relations: each relation the query uses, once, in the order its
      #   text first names it, as an Array of {"schema", "name"} Hashes.
      #
      # Anything that fails writes nothing. Its only line is DONE: the
      # query and its literals stay in the store, and the driver sees the
      # schema only as 3b's subset. A refusal names only its rule.
      module Qualify
        module_function

        def call(store:, **)
          query = store.read("query")
          settings = store.read("plan")[0]["Settings"]
          result = check(store.read("server"), query, settings)
          store.write("relations", result.relations.map { { "schema" => it.schema, "name" => it.name } })
          store.write("qualified_query", result.sql)
          []
        end

        def check(host, query, settings)
          connection = Enclave::Inventory::Production.connect(host)
          Relations.check(query, settings, connection)
        ensure
          connection&.close
        end
      end
    end
  end
end
