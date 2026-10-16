# frozen_string_literal: true

require "json"
require_relative "relation_qualifier"

module Quaack
  module Enclave
    # Where tables sit (DESIGN.md's qualify and run-server): the tablespace
    # of each table, of its TOAST table and that table's index, and of each
    # of its indexes, by name. qualify reads it on production, and
    # run-server on the racetrack, to compare the two.
    #
    #   Placement.read(connection, [["sales", "orders"]])
    #   # => [{ "schema" => "sales", "name" => "orders",
    #   #       "tablespaces" => { "table" => "pg_default", "toast" => "pg_default",
    #   #                          "toast_index" => "pg_default", "index orders_note_idx" => "fast" } }]
    #
    # A relation with no tablespace of its own is in the database's
    # default, which stands under its own name. The TOAST table and its
    # index go under fixed keys, since their names hold the table's OID,
    # which differs between servers. A table missing from pg_class has no
    # entry. Tablespace names are production configuration, so a placement
    # never leaves the enclave.
    module Placement
      SQL = <<~SQL
        WITH tables AS (
          SELECT q.nspname, q.relname, c.oid, c.reltoastrelid
          FROM ROWS FROM (pg_catalog.unnest($1::pg_catalog.text[]),
                          pg_catalog.unnest($2::pg_catalog.text[])) AS q(nspname, relname)
          JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) q.nspname
          JOIN pg_catalog.pg_class c ON c.relnamespace OPERATOR(pg_catalog.=) n.oid
                                    AND c.relname OPERATOR(pg_catalog.=) q.relname
        ), members AS (
          SELECT oid AS owner, 'table'::pg_catalog.text AS member, oid AS relid FROM tables
          UNION ALL
          SELECT oid, 'toast'::pg_catalog.text, reltoastrelid FROM tables
          WHERE reltoastrelid OPERATOR(pg_catalog.<>) 0::pg_catalog.oid
          UNION ALL
          SELECT t.oid, 'toast_index'::pg_catalog.text, i.indexrelid
          FROM tables t JOIN pg_catalog.pg_index i ON i.indrelid OPERATOR(pg_catalog.=) t.reltoastrelid
          WHERE t.reltoastrelid OPERATOR(pg_catalog.<>) 0::pg_catalog.oid
          UNION ALL
          SELECT t.oid, 'index '::pg_catalog.text OPERATOR(pg_catalog.||) ic.relname::pg_catalog.text, i.indexrelid
          FROM tables t
          JOIN pg_catalog.pg_index i ON i.indrelid OPERATOR(pg_catalog.=) t.oid
          JOIN pg_catalog.pg_class ic ON ic.oid OPERATOR(pg_catalog.=) i.indexrelid
        )
        SELECT t.nspname, t.relname, (
          SELECT pg_catalog.json_object_agg(m.member, s.spcname ORDER BY m.member)
          FROM members m
          JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) m.relid
          JOIN pg_catalog.pg_tablespace s ON s.oid OPERATOR(pg_catalog.=) CASE
            WHEN c.reltablespace OPERATOR(pg_catalog.=) 0::pg_catalog.oid
            THEN (SELECT dattablespace FROM pg_catalog.pg_database
                  WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database())
            ELSE c.reltablespace END
          WHERE m.owner OPERATOR(pg_catalog.=) t.oid)
        FROM tables t
        ORDER BY t.nspname, t.relname
      SQL

      module_function

      # tables is [schema, name] pairs.
      def read(connection, tables)
        tables = tables.uniq
        params = [RelationQualifier.text_array(tables.map(&:first)), RelationQualifier.text_array(tables.map(&:last))]
        connection.exec_params(SQL, params).values.map do |schema, name, json|
          { "schema" => schema, "name" => name, "tablespaces" => JSON.parse(json) }
        end
      end

      QUOTED_SQL = "SELECT pg_catalog.quote_ident($1) OPERATOR(pg_catalog.||) '.' " \
                   "OPERATOR(pg_catalog.||) pg_catalog.quote_ident($2)"

      # The tables of production, a placement qualify read there, that sit
      # elsewhere on connection's server: where a member both servers have,
      # the table itself, its TOAST table, or an index of the same name, is
      # in another tablespace. Each is its schema.name, as quote_ident writes
      # them, which is schema, never a tablespace's name. A table or index
      # missing here isn't a tablespace's doing, so it isn't counted.
      def moves(connection, production)
        here = read(connection, production.map { [it["schema"], it["name"]] })
        production.filter_map do |table|
          key = table.values_at("schema", "name")
          found = here.find { it.values_at("schema", "name") == key } or next
          next unless moved?(table["tablespaces"], found["tablespaces"])

          connection.exec_params(QUOTED_SQL, key).getvalue(0, 0)
        end
      end

      def moved?(ours, theirs) = (ours.keys & theirs.keys).any? { ours[it] != theirs[it] }

      # Every tablespace placement names, sorted.
      def tablespaces(placement) = placement.flat_map { it["tablespaces"].values }.uniq.sort
    end
  end
end
