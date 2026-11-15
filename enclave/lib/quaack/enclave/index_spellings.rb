# frozen_string_literal: true

require "pg"
require_relative "build_order"

module Quaack
  module Enclave
    # Two spellings of one index, such as an LLM's `status <> 'deleted'`
    # and Postgres's `status::text <> 'deleted'::text` (20261018-30), are
    # built once (20261018-32). HypoPG defines each DDL the way Postgres
    # would, so DDLs whose definitions match are one index.
    #
    #   IndexSpellings.kept(connection, combinations)  # { ddl => kept ddl }
    #   IndexSpellings.ddls(connection, combinations)  # what to build, in order
    #
    # The definitions can hold a literal, so they never leave this module.
    module IndexSpellings
      SCHEMA_SQL = "SELECT n.nspname FROM pg_catalog.pg_extension e " \
                   "JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) e.extnamespace " \
                   "WHERE e.extname OPERATOR(pg_catalog.=) 'hypopg'"

      module_function

      # HypoPG's definition of the hypothetical index $1 creates.
      def definition_sql(schema)
        "SELECT #{schema}.hypopg_get_indexdef(indexrelid) FROM #{schema}.hypopg_create_index($1)"
      end

      def reset_sql(schema) = "SELECT #{schema}.hypopg_reset()"

      # BuildOrder's DDLs, keeping only the first of each set of spellings.
      def ddls(connection, combinations)
        kept = kept(connection, combinations)
        BuildOrder.ddls(combinations).uniq { kept[it] }
      end

      # { ddl => the first DDL, in BuildOrder's order, that HypoPG defines
      # the same way } for each DDL in combinations. A DDL HypoPG can't
      # create, such as a GIN one, stands for itself, as does every DDL on
      # a server without HypoPG.
      def kept(connection, combinations)
        ddls = BuildOrder.ddls(combinations)
        schema = connection.exec(SCHEMA_SQL).values.dig(0, 0)&.then { connection.quote_ident(it) }
        return ddls.to_h { [it, it] } unless schema

        firsts = {}
        ddls.to_h { |ddl| [ddl, firsts[definition(connection, schema, ddl)] ||= ddl] }
      ensure
        connection.exec(reset_sql(schema)) if schema
      end

      # HypoPG's definition of ddl, which names no index, or ddl itself if
      # HypoPG won't create it.
      def definition(connection, schema, ddl)
        connection.exec(reset_sql(schema))
        connection.exec_params(definition_sql(schema), [ddl]).getvalue(0, 0)
      rescue PG::Error
        ddl
      end
    end
  end
end
