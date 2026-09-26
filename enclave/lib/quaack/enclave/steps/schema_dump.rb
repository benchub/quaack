# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../schema_dump"
require_relative "../table_name"

module Quaack
  module Enclave
    module Steps
      # `quaacks schema-dump --run <run ID>` (README 3b): the schema-only
      # dump of the query's namespaces plus public, and the subset, the
      # query's tables and their FK ancestors (see Enclave::SchemaDump).
      #
      # It reads the run's server and relations entries, the latter written
      # by `quaacks qualify`. It connects to the server as step 2 does
      # (Inventory::Production.connect) and reads the catalog inside
      # Production.read_only. pg_dump runs from PATH with the operator's own
      # libpq setup, given only the run's host, as the connection is.
      #
      # It writes two entries:
      #
      # - schema_dump: {"namespaces" => [...], "ddl" => "<pg_dump output>"},
      #   for 4a, which loads the full schema into the arena.
      # - schema_subset: {"tables" => [[schema, name], ...], "ddl" => "..."},
      #   the only schema the LLM and the fixture generator see. This step
      #   doesn't send it: the payload step for 5a-5 reads it from here.
      #
      # SchemaDump.run writes both only once every read and both dumps
      # have succeeded, so a failure stores nothing. Its only line is DONE. A
      # refusal names only its rule.
      module SchemaDump
        module_function

        def call(store:, **)
          host = store.read("server")
          relations = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          connection = Enclave::Inventory::Production.connect(host)
          Enclave::Inventory::Production.read_only(connection) do
            Enclave::SchemaDump.run(store:, relations:, connection:, conninfo: { host: })
          end
          []
        ensure
          connection&.close
        end
      end
    end
  end
end
