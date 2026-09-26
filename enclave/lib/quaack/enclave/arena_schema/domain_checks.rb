# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    class ArenaSchema
      # Domain CHECKs, as CHECKs on the columns of the domain's type.
      module DomainChecks
        # Each column's domain CHECKs, from its domain and the domains that
        # domain is built on, as column name and pg_get_constraintdef.
        QUERY = <<~SQL
          WITH RECURSIVE d(attname, typid) AS (
            SELECT a.attname, a.atttypid FROM pg_attribute a
            WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            UNION ALL
            SELECT d.attname, t.typbasetype FROM d JOIN pg_type t ON t.oid = d.typid WHERE t.typtype = 'd'
          )
          SELECT d.attname, pg_get_constraintdef(c.oid)
          FROM d JOIN pg_constraint c ON c.contypid = d.typid
          WHERE c.contype = 'c' AND c.convalidated
          ORDER BY d.attname, c.conname
        SQL

        module_function

        # A domain CHECK tests VALUE. Each becomes a CHECK on its column.
        def read(conn, regclass)
          conn.exec_params(QUERY, [regclass]).values.map do |column, definition|
            tree = PgQuery.parse("SELECT 1 WHERE #{definition.delete_prefix("CHECK ")}").tree
            rename_value(tree, column)
            "CHECK (#{PgQuery.deparse(tree).sub(/\ASELECT 1 WHERE /, "")})"
          end
        end

        def value_ref?(node)
          node.is_a?(PgQuery::ColumnRef) && node.fields.size == 1 && node.fields[0].string&.sval == "value"
        end

        def rename_value(node, column)
          case node
          when Google::Protobuf::RepeatedField then node.each { |c| rename_value(c, column) }
          when Google::Protobuf::MessageExts
            node.fields[0].string.sval = column if value_ref?(node)
            node.class.descriptor.each { |field| rename_value(field.get(node), column) }
          end
        end
      end
    end
  end
end
