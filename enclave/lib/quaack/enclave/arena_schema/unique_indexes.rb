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
          SELECT pg_catalog.array_to_json(ARRAY(
                   SELECT a.attname FROM pg_catalog.unnest(i.indkey::pg_catalog.int2[]) WITH ORDINALITY k(n, o)
                   JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) i.indrelid AND a.attnum OPERATOR(pg_catalog.=) k.n
                   WHERE k.o OPERATOR(pg_catalog.<=) i.indnkeyatts ORDER BY k.o)),
                 i.indexprs IS NOT NULL, i.indnullsnotdistinct,
                 pg_catalog.array_to_json(ARRAY(SELECT pg_catalog.pg_get_indexdef(i.indexrelid, k, true)
                   FROM pg_catalog.generate_series(1, i.indnkeyatts) k ORDER BY k)),
                 pg_catalog.array_to_json(ARRAY(SELECT DISTINCT a.attname FROM pg_catalog.pg_depend d
                   JOIN pg_catalog.pg_attribute a
                     ON a.attrelid OPERATOR(pg_catalog.=) d.refobjid AND a.attnum OPERATOR(pg_catalog.=) d.refobjsubid
                   WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                     AND d.objid OPERATOR(pg_catalog.=) i.indexrelid
                     AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                     AND d.refobjid OPERATOR(pg_catalog.=) i.indrelid AND d.refobjsubid OPERATOR(pg_catalog.>) 0)),
                 EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                   JOIN pg_catalog.pg_proc p ON p.oid OPERATOR(pg_catalog.=) d.refobjid
                   WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                     AND d.objid OPERATOR(pg_catalog.=) i.indexrelid
                     AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_proc'::pg_catalog.regclass
                     AND p.pronamespace OPERATOR(pg_catalog.<>) 'pg_catalog'::pg_catalog.regnamespace)
          FROM pg_catalog.pg_index i
          WHERE i.indrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass AND i.indisunique AND i.indisvalid
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
