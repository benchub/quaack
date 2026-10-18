# frozen_string_literal: true

require "pg_query"
require_relative "../../redaction"
require_relative "../../supported_sql"
require_relative "../../volatility_check"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # Catalog facts about one SELECT standing on its own, for a rule
        # that moves a subquery. Each answer is kept for the life of the
        # Catalog.
        module Standalone
          # Each type's name, as format_type gives it with no typmod, in
          # the order of the oids.
          TYPE_NAMES = <<~SQL
            SELECT pg_catalog.format_type(u.t, NULL)
            FROM pg_catalog.unnest($1::pg_catalog.oid[]) WITH ORDINALITY AS u(t, n) ORDER BY u.n
          SQL

          # Whether Postgres can analyze sql, one SELECT with $n
          # placeholders, by itself: every name in it resolves inside it.
          # Each placeholder is left for Postgres to type, or text where
          # nothing types it, as Redaction.prepare does. It's prepared and
          # deallocated, never run, and no literal is involved.
          def self_contained?(sql)
            @self_contained ||= {}
            @self_contained.fetch(sql) { @self_contained[sql] = prepares?(sql) }
          end

          # The types of the columns sql, one SELECT with $n placeholders,
          # would give, as format_type names them with no typmod, such as
          # integer or timestamp with time zone. A domain gives its base
          # type, as Postgres describes it.
          # Placeholders are typed as self_contained? types them. nil if
          # Postgres can't analyze it. It's prepared, described, and
          # deallocated, never run.
          def result_types(sql)
            @result_types ||= {}
            @result_types.fetch(sql) { @result_types[sql] = described(sql) }
          end

          # Whether sql might call a volatile function, by volatility's
          # VolatilityCheck with the connection's search path. SQL it can't
          # check counts as volatile.
          def calls_volatile?(sql)
            @volatile ||= {}
            @volatile.fetch(sql) { @volatile[sql] = volatile?(sql) }
          end

          private

          def prepares?(sql)
            prepared(sql) { nil }
            true
          rescue Redaction::Error, PgQuery::ParseError
            false
          end

          def described(sql)
            oids = prepared(sql) do |name|
              result = @connection.describe_prepared(name)
              Array.new(result.nfields) { result.ftype(it) }
            end
            @connection.exec_params(TYPE_NAMES, ["{#{oids.join(",")}}"]).column_values(0)
          rescue Redaction::Error, PgQuery::ParseError
            nil
          end

          # What the block gives for the name sql is prepared as, which is
          # deallocated after.
          def prepared(sql)
            @prepared = (@prepared || 0) + 1
            name = "quaack_catalog_#{@prepared}"
            Redaction.prepare(@connection, name, sql, Array.new(placeholders(sql), "unknown"))
            begin
              yield name
            ensure
              @connection.exec("DEALLOCATE #{name}")
            end
          end

          # The highest $n in sql.
          def placeholders(sql) = Tree.find(PgQuery.parse(sql).tree, PgQuery::ParamRef).map(&:number).max.to_i

          def volatile?(sql)
            VolatilityCheck.check(sql, nil, @connection)
            false
          rescue VolatilityCheck::Error, SupportedSql::Error
            true
          end
        end
      end
    end
  end
end
