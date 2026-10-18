# frozen_string_literal: true

require "pg_query"
require_relative "../../assumption_check"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # Names a type written as in a cast, for a rule that must know
        # whether a cast is to a column's own type:
        #
        #   catalog.type_name("numeric(5, 1)")   # => "numeric(5,1)"
        #   catalog.type_name("int4")            # => "integer"
        #
        # That's how column_info names a column's type, modifiers included,
        # with the connection's search path. A type that doesn't exist, or
        # text that isn't a type name alone, gives nil. Each answer is kept
        # for the life of the Catalog.
        #
        # It also says whether a column's type is a row type, for a rule
        # that tests a column with IS NOT NULL:
        #
        #   catalog.row_type?("public", "orders", "ship_to")   # => true
        module Types
          EQ = "OPERATOR(pg_catalog.=)"

          # format_type and to_regtype give NULL for a type that doesn't
          # exist. to_regtype raises on text that doesn't parse as a type,
          # which type_syntax? keeps from it.
          TYPE_NAME = <<~SQL
            SELECT pg_catalog.format_type(pg_catalog.to_regtype($1), pg_catalog.to_regtypemod($1))
          SQL

          # The column's type and, for a domain, the types under it, down to
          # one that isn't a domain: any composite among them?
          ROW_TYPE = <<~SQL.freeze
            WITH RECURSIVE types (type) AS (
              SELECT a.atttypid FROM pg_catalog.pg_attribute a
              WHERE a.attrelid #{EQ} #{AssumptionCheck::RELATION} AND a.attname #{EQ} $3 AND a.attnum OPERATOR(pg_catalog.>) 0
              UNION ALL
              SELECT t.typbasetype FROM types JOIN pg_catalog.pg_type t ON t.oid #{EQ} types.type
              WHERE t.typtype #{EQ} 'd'
            )
            SELECT EXISTS (SELECT 1 FROM types JOIN pg_catalog.pg_type t ON t.oid #{EQ} types.type
                           WHERE t.typtype #{EQ} 'c')
          SQL

          def type_name(type)
            @type_names ||= {}
            @type_names.fetch(type) do
              @type_names[type] = (@connection.exec_params(TYPE_NAME, [type]).getvalue(0, 0) if type_syntax?(type))
            end
          end

          # Whether the column's type is a composite type, or a domain over
          # one. Postgres tests each field of such a value for IS NULL and
          # IS NOT NULL, so a row of NULLs is neither, though it isn't NULL
          # itself. A column that doesn't exist isn't one.
          def row_type?(schema, table, column)
            @row_types ||= {}
            @row_types.fetch([schema, table, column]) do
              @row_types[[schema, table, column]] =
                @connection.exec_params(ROW_TYPE, [schema, table, column]).getvalue(0, 0) == "t"
            end
          end

          private

          # Whether type reads as a type name alone: SELECT NULL::type
          # parses as SELECT NULL::int does, with only the type changed.
          # That's how to_regtype reads it.
          def type_syntax?(type)
            parsed = PgQuery.parse(format("SELECT NULL::%s", type)).tree
            cast = Tree.find(parsed, PgQuery::TypeCast).first
            return false unless cast

            plain = PgQuery.parse("SELECT NULL::int").tree
            Tree.find(plain, PgQuery::TypeCast).first.type_name = Deparse.copy(cast.type_name)
            [parsed, plain].each { Deparse.clear_locations(it) }
            parsed == plain
          rescue PgQuery::ParseError
            false
          end
        end
      end
    end
  end
end
