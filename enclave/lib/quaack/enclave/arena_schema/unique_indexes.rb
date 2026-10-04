# frozen_string_literal: true

require "json"
require "pg_query"

module Quaack
  module Enclave
    class ArenaSchema
      # A table's unique indexes, for Constraints.
      module UniqueIndexes
        # Every valid unique index: its key columns (not INCLUDE ones),
        # whether any key is an expression, NULLS NOT DISTINCT, each key as
        # text, the columns it reads, and whether it calls a function
        # outside pg_catalog.
        QUERY = <<~SQL
          SELECT array_to_json(ARRAY(SELECT a.attname FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(n, o)
                   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.n
                   WHERE k.o <= i.indnkeyatts ORDER BY k.o)),
                 i.indexprs IS NOT NULL, i.indnullsnotdistinct,
                 array_to_json(ARRAY(SELECT pg_get_indexdef(i.indexrelid, k, true)
                   FROM generate_series(1, i.indnkeyatts) k ORDER BY k)),
                 array_to_json(ARRAY(SELECT DISTINCT a.attname FROM pg_depend d
                   JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
                   WHERE d.classid = 'pg_class'::regclass AND d.objid = i.indexrelid
                     AND d.refclassid = 'pg_class'::regclass AND d.refobjid = i.indrelid AND d.refobjsubid > 0)),
                 EXISTS (SELECT 1 FROM pg_depend d JOIN pg_proc p ON p.oid = d.refobjid
                   WHERE d.classid = 'pg_class'::regclass AND d.objid = i.indexrelid
                     AND d.refclassid = 'pg_proc'::regclass AND p.pronamespace <> 'pg_catalog'::regnamespace)
          FROM pg_index i
          WHERE i.indrelid = $1::regclass AND i.indisunique AND i.indisvalid
        SQL

        module_function

        # Constraints' uniques (keys, the constraints' own, plus the plain
        # indexes'), expressions, nulls_not_distinct, and user_function.
        def read(conn, regclass, keys)
          rows = conn.exec_params(QUERY, [regclass]).values
          expr, plain = rows.partition { |r| r[1] == "t" }
          { uniques: keys + columns(plain), nulls_not_distinct: columns(plain.select { |r| r[2] == "t" }),
            expressions: expr.map { |r| expression(r) }, user_function: expr.any? { |r| r[5] == "t" } }
        end

        def columns(rows) = rows.map { |r| JSON.parse(r[0]) }

        def expression(row)
          _, _, nnd, keys, reads, = row
          keys = JSON.parse(keys)
          columns = JSON.parse(reads)
          ExpressionUnique.new(columns:, keys:, nulls_not_distinct: nnd == "t",
                               key_columns: key_columns(keys) || columns)
        end

        # The columns the keys read, those that are a key on their own
        # first, then the rest, in key order.
        def key_columns(keys)
          bare, inner = keys.map { target(it) }.partition { it.res_target.val.column_ref }
          (bare + inner).flat_map { column_refs(it) }.uniq
        rescue PgQuery::ParseError
          nil
        end

        def target(key) = PgQuery.parse("SELECT #{key}").tree.stmts[0].stmt.select_stmt.target_list[0]

        def column_refs(node, found = [])
          found << node.fields.last.string.sval if node.is_a?(PgQuery::ColumnRef) && node.fields.last&.string
          children(node).each { column_refs(it, found) }
          found
        end

        def children(node)
          case node
          when Google::Protobuf::RepeatedField then node.to_a
          when Google::Protobuf::MessageExts then node.class.descriptor.map { |field| field.get(node) }
          else []
          end
        end
      end
    end
  end
end
