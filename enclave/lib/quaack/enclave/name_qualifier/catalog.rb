# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module NameQualifier
      # Which schemas on the path have a function, operator, type,
      # collation, or relation of a name, read from the catalog once each.
      class Catalog
        # Each kind's catalog, its namespace column, and its name column.
        CATALOGS = {
          function: %w[pg_proc pronamespace proname],
          operator: %w[pg_operator oprnamespace oprname],
          type: %w[pg_type typnamespace typname],
          collation: %w[pg_collation collnamespace collname],
          relation: %w[pg_class relnamespace relname]
        }.freeze

        # Collations count only for the database's encoding, or any encoding.
        EXTRA = {
          collation: " AND o.collencoding OPERATOR(pg_catalog.=) ANY " \
                     "(ARRAY[-1, pg_catalog.pg_char_to_encoding(pg_catalog.getdatabaseencoding())])"
        }.freeze

        # The schemas on path $1 the role may use that have one of name $2,
        # in path order.
        SQL = CATALOGS.to_h do |kind, (table, namespace, name)|
          [kind, <<~SQL]
            SELECT n.nspname
            FROM pg_catalog.unnest($1::pg_catalog.text[]) WITH ORDINALITY AS path(nspname, position)
            JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) path.nspname
            WHERE pg_catalog.has_schema_privilege(n.oid, 'USAGE')
              AND EXISTS (SELECT FROM pg_catalog.#{table} o
                          WHERE o.#{namespace} OPERATOR(pg_catalog.=) n.oid
                            AND o.#{name} OPERATOR(pg_catalog.=) $2#{EXTRA.fetch(kind, "")})
            ORDER BY path.position
          SQL
        end.freeze

        def initialize(path, connection)
          # A text[] literal with every element quoted.
          @path = "{#{path.map { %("#{it.gsub(/["\\]/) { |char| "\\#{char}" }}") }.join(",")}}"
          @connection = connection
          @schemas = {}
        end

        def schemas(kind, name)
          @schemas[[kind, name]] ||= @connection.exec_params(SQL.fetch(kind), [@path, name]).column_values(0).uniq
        end

        # The schema to name for a name, or nil to leave it bare: with pick
        # :first, the first schema that has it, and with :only, the one
        # schema that has it, if there's only one. Never pg_catalog.
        def schema(kind, name, pick)
          found = schemas(kind, name)
          schema = pick == :first || found.size == 1 ? found.first : nil
          schema unless schema == "pg_catalog"
        end

        # A one-name list, with the schema named if there's one to name.
        def qualified(kind, names, pick)
          schema = schema(kind, names.first.string.sval, pick)
          schema ? [PgQuery::Node.new(string: PgQuery::String.new(sval: schema)), *names.to_a] : names.to_a
        end
      end
    end
  end
end
