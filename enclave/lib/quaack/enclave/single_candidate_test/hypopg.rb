# frozen_string_literal: true

module Quaack
  module Enclave
    module SingleCandidateTest
      # HypoPG's functions, called in the extension's own schema, which
      # CREATE EXTENSION picked and need not be on the search_path. So a
      # same-named function in a schema ahead of it can't answer instead.
      module HypoPG
        SCHEMA_SQL = "SELECT n.nspname FROM pg_catalog.pg_extension e " \
                     "JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) e.extnamespace " \
                     "WHERE e.extname OPERATOR(pg_catalog.=) 'hypopg'"

        module_function

        # HypoPG's schema, quoted. Without HypoPG, an Error with rule and
        # 42883, undefined_function, as calling one of its functions would
        # raise.
        def schema(connection, rule)
          schema = connection.exec(SCHEMA_SQL).values.dig(0, 0)
          raise Error.new(rule, "42883"), cause: nil unless schema

          connection.quote_ident(schema)
        end

        def create_sql(schema)
          "SELECT indexrelid, indexname, #{schema}.hypopg_relation_size(indexrelid) " \
            "FROM #{schema}.hypopg_create_index($1)"
        end

        def reset_sql(schema) = "SELECT #{schema}.hypopg_reset()"

        def hidden_count_sql(schema) = "SELECT pg_catalog.count(*) FROM #{schema}.hypopg_hidden_indexes()"
      end
    end
  end
end
