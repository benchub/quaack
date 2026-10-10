# frozen_string_literal: true

require_relative "../inventory/production"
require_relative "../plan_tables"
require_relative "../relations"

module Quaack
  module Enclave
    module Steps
      # `quaacks qualify --run <run ID>` (DESIGN.md, input and qualify): fully
      # qualifies the run's query against its production server, and checks
      # that every relation it uses is a plain table (see Relations), and that
      # every table the plan scans is one the query reads (see PlanTables).
      #
      # It reads the run's query, plan, server, and production_port entries. It connects to
      # the server with the operator's libpq setup, as inventory does
      # (Inventory::Production.connect), and resolves names through the
      # search_path in the plan's SETTINGS, or the default path without one.
      # Only the catalog is read, with plain SELECTs, inside one
      # Production.read_only transaction, so a failed read is
      # production_read_failed, with its SQLSTATE.
      #
      # It writes three entries, for later steps to read:
      #
      # - qualified_query: the query's text with every relation naming its
      #   schema, a String. It holds the query's literals.
      # - relations: each relation the query uses, once, in the order its
      #   text first names it, as an Array of {"schema", "name"} Hashes.
      # - search_path: the plan's search path, or the default, as an Array of
      #   schema names in order, with "$user" as the role it connects as,
      #   and without any schema that role may not use. It lists pg_catalog
      #   only where the path does, so a session that sets it searches what
      #   qualify did. RunServer.connect sets it, and rewrite-check
      #   qualifies a candidate through it.
      #
      # Anything that fails writes nothing. Its only line is DONE: the
      # query and its literals stay in the store, and the driver sees the
      # schema only as schema-dump's subset. A refusal names only its rule.
      module Qualify
        module_function

        def call(store:, **)
          query = store.read("query")
          plan = store.read("plan")
          result, path, tablespaces = check(Enclave::Inventory::Production.params(store), query, plan)
          store.write("relations", result.relations.map { { "schema" => it.schema, "name" => it.name } })
          store.write("relation_tablespaces", tablespaces)
          store.write("search_path", path)
          store.write("qualified_query", result.sql)
          []
        end

        def check(production, query, plan)
          settings = plan[0]["Settings"]
          connection = Enclave::Inventory::Production.connect(production)
          Enclave::Inventory::Production.read_only(connection) do
            result = Relations.check(query, settings, connection)
            PlanTables.check!(plan, result.scanned)
            [result, written_path(settings, connection), tablespaces(result.scanned, connection)]
          end
        ensure
          connection&.close
        end

        # The tablespaces of tables $1 (schemas) and $2 (names) and of their
        # indexes, by name, sorted. A relation with none of its own is in the
        # database's default tablespace, which stands under its own name.
        TABLESPACES_SQL = <<~SQL
          WITH tables AS (
            SELECT c.oid
            FROM ROWS FROM (pg_catalog.unnest($1::pg_catalog.text[]),
                            pg_catalog.unnest($2::pg_catalog.text[])) AS q(nspname, relname)
            JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) q.nspname
            JOIN pg_catalog.pg_class c ON c.relnamespace OPERATOR(pg_catalog.=) n.oid
                                      AND c.relname OPERATOR(pg_catalog.=) q.relname
          ), used AS (
            SELECT oid FROM tables
            UNION
            SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid OPERATOR(pg_catalog.=) ANY (ARRAY(SELECT oid FROM tables))
          )
          SELECT DISTINCT s.spcname
          FROM used
          JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) used.oid
          JOIN pg_catalog.pg_tablespace s ON s.oid OPERATOR(pg_catalog.=) CASE
            WHEN c.reltablespace OPERATOR(pg_catalog.=) 0::pg_catalog.oid
            THEN (SELECT dattablespace FROM pg_catalog.pg_database
                  WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database())
            ELSE c.reltablespace END
          ORDER BY s.spcname
        SQL

        def tablespaces(scanned, connection)
          connection.exec_params(TABLESPACES_SQL, [RelationQualifier.text_array(scanned.map(&:schema)),
                                                   RelationQualifier.text_array(scanned.map(&:name))])
                    .column_values(0)
        end

        # The schemas of path $1, in order, but those that exist and the
        # role may not use, which Postgres skips.
        USABLE_SQL = <<~SQL
          SELECT path.nspname
          FROM pg_catalog.unnest($1::pg_catalog.text[]) WITH ORDINALITY AS path(nspname, position)
          WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_namespace n
                            WHERE n.nspname OPERATOR(pg_catalog.=) path.nspname
                              AND NOT pg_catalog.has_schema_privilege(n.oid, 'USAGE'))
          ORDER BY path.position
        SQL

        # The path as the plan wrote it, with "$user" as the role qualify
        # connects as, and without the schemas that role may not use, so a
        # later step, which connects to the run server as another role,
        # searches what qualify did. Relations.check has read it already.
        def written_path(settings, connection)
          user = connection.exec("SELECT current_user").getvalue(0, 0)
          path = RelationQualifier.path_entries(settings).map { it == "$user" ? user : it }
          connection.exec_params(USABLE_SQL, [RelationQualifier.text_array(path)]).column_values(0)
        end
      end
    end
  end
end
