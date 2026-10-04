# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../volatility_check"

module Quaack
  module Enclave
    module Steps
      # `quaacks volatility --run <run ID>` (DESIGN.md's volatility): refuses the run's
      # query if it calls a volatile function anywhere (see VolatilityCheck).
      #
      # It reads the run's server, plan, and qualified_query entries, the
      # last written by `quaacks qualify`. It connects to the server as
      # inventory does (Inventory::Production.connect), and VolatilityCheck reads
      # the catalog inside one Production.read_only transaction, resolving
      # unqualified function names through the search_path in the plan's
      # SETTINGS, or the default path without one.
      #
      # volatility is a gate, so the only thing to store is that it passed: the
      # entry volatility, {"passed" => true}, which later steps can require
      # before they run the query. It's written only after the transaction
      # has closed, so a refusal or a failed read stores nothing. Its only
      # line is DONE. A refusal names only its rule, such as
      # volatile_function, whose error line also names the volatile
      # function, schema-qualified (see ErrorFilter), never an argument.
      module Volatility
        ENTRY = "volatility"

        module_function

        def call(store:, **)
          query = store.read("qualified_query")
          settings = store.read("plan")[0]["Settings"]
          check(store.read("server"), query, settings)
          store.write(ENTRY, { "passed" => true })
          []
        end

        def check(host, query, settings)
          connection = Enclave::Inventory::Production.connect(host)
          Enclave::Inventory::Production.read_only(connection) do
            VolatilityCheck.check(query, settings, connection)
          end
        ensure
          connection&.close
        end
      end
    end
  end
end
