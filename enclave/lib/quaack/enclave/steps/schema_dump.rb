# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../schema_dump"
require_relative "../table_name"

module Quaack
  module Enclave
    module Steps
      # `quaacks schema-dump --run <run ID>` (DESIGN.md's schema-dump): the schema-only
      # dump of the namespaces of the query's tables and their FK ancestors,
      # plus public, and the subset, the query's tables and their FK
      # ancestors (see Enclave::SchemaDump).
      #
      # It reads the run's server and relations entries, the latter written
      # by `quaacks qualify`. It connects to the server as inventory does
      # (Inventory::Production.connect) and reads the catalog inside
      # Production.read_only. pg_dump runs from PATH with the operator's own
      # libpq setup, given only the run's host, as the connection is.
      #
      # It writes two entries:
      #
      # - schema_dump: {"namespaces" => [...], "ddl" => "<pg_dump output>"},
      #   for racetrack-setup, which loads the full schema into the arena.
      # - schema_subset: {"tables" => [[schema, name], ...], "ddl" => "..."},
      #   the only schema the LLM and the fixture generator see. This step
      #   doesn't send it: the payload step for llm-index-ideas reads it from here.
      #
      # SchemaDump.run writes both only once every read and both dumps
      # have succeeded, so a failure stores nothing. Its only line is DONE. A
      # refusal names only its rule.
      module SchemaDump
        # Holds SchemaDump's entries until the read-only transaction has
        # ended. The connection sits idle in that transaction while pg_dump
        # runs, and production can end the session, so the transaction's
        # end can still fail after both dumps are done. Writing only then
        # keeps that failure from leaving entries behind.
        class Pending
          attr_reader :entries

          def initialize = @entries = {}
          def write(name, data) = @entries[name] = data
        end

        module_function

        def call(store:, **)
          host = store.read("server")
          relations = store.read("relations").map { TableName.new(schema: it["schema"], name: it["name"]) }
          connection = Enclave::Inventory::Production.connect(host)
          dumped(connection, relations, host).entries.each { |name, data| store.write(name, data) }
          []
        ensure
          connection&.close
        end

        def dumped(connection, relations, host)
          Pending.new.tap do |pending|
            Enclave::Inventory::Production.read_only(connection) do
              Enclave::SchemaDump.run(store: pending, relations:, connection:, conninfo: { host: })
            end
          end
        end
      end
    end
  end
end
