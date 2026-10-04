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
          # Whether Postgres can analyze sql, one SELECT with $n
          # placeholders, by itself: every name in it resolves inside it.
          # Each placeholder is left for Postgres to type, or text where
          # nothing types it, as Redaction.prepare does. It's prepared and
          # deallocated, never run, and no literal is involved.
          def self_contained?(sql)
            @self_contained ||= {}
            @self_contained.fetch(sql) { @self_contained[sql] = prepares?(sql) }
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
            @prepared = (@prepared || 0) + 1
            name = "quaack_catalog_#{@prepared}"
            Redaction.prepare(@connection, name, sql, Array.new(placeholders(sql), "unknown"))
            @connection.exec("DEALLOCATE #{name}")
            true
          rescue Redaction::Error, PgQuery::ParseError
            false
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
