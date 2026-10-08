# frozen_string_literal: true

require "json"
require_relative "../../assumption_check"

module Quaack
  module Enclave
    module RewriteRules
      class Catalog
        # For a rule that removes a join on a foreign key, whether the key
        # binds every row of its table, so each row has exactly one row it
        # references:
        #
        #   catalog.strict_foreign_key?(%w[public posts], %w[public users], [%w[user_id id]])   # => true
        module ForeignKeys
          EQ = "OPERATOR(pg_catalog.=)"

          # The column pairs, [child, parent], of each foreign key from table
          # ($1, $2) to references_table ($3, $4) that binds every row of the
          # child at every moment, as JSON: not deferrable, with its triggers
          # firing, between two plain tables with no inheritance parent or
          # child, a partition being one, onto a table with no row-level
          # security. Whether it's validated, and so enforced, is the
          # foreign_key assumption's to say (see AssumptionCheck). A pair is
          # left out unless both columns have a deterministic collation or
          # none, and = between two of the child column's type is one
          # operator, the foreign key's own, so the two columns have one type
          # and the query's = is the one the key was checked with.
          #
          # ROWS FROM, since only an unqualified unnest takes several arrays.
          STRICT_FOREIGN_KEY = <<~SQL.freeze
            SELECT pg_catalog.array_to_json(ARRAY(
                     SELECT ARRAY[a.attname::pg_catalog.text, r.attname::pg_catalog.text]
                     FROM ROWS FROM (pg_catalog.unnest(c.conkey), pg_catalog.unnest(c.confkey),
                                     pg_catalog.unnest(c.conpfeqop)) AS u(k, f, op)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} c.conrelid AND a.attnum #{EQ} u.k
                     JOIN pg_catalog.pg_attribute r ON r.attrelid #{EQ} c.confrelid AND r.attnum #{EQ} u.f
                     WHERE ARRAY(SELECT o.oid FROM pg_catalog.pg_operator o
                                 WHERE o.oprname #{EQ} '=' AND o.oprleft #{EQ} a.atttypid
                                   AND o.oprright #{EQ} a.atttypid)
                           #{EQ} ARRAY[u.op]
                       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_collation co
                                       WHERE (co.oid #{EQ} a.attcollation OR co.oid #{EQ} r.attcollation)
                                         AND NOT co.collisdeterministic)))::pg_catalog.text
            FROM pg_catalog.pg_constraint c
            JOIN pg_catalog.pg_class ch ON ch.oid #{EQ} c.conrelid
            JOIN pg_catalog.pg_class pa ON pa.oid #{EQ} c.confrelid
            WHERE c.conrelid #{EQ} #{AssumptionCheck::RELATION} AND c.contype #{EQ} 'f' AND NOT c.condeferrable
              AND c.confrelid #{EQ} #{AssumptionCheck::RELATION.sub("$1", "$3").sub("$2", "$4")}
              AND ch.relkind #{EQ} 'r' AND pa.relkind #{EQ} 'r' AND NOT pa.relrowsecurity
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i
                              WHERE i.inhrelid #{EQ} ch.oid OR i.inhrelid #{EQ} pa.oid
                                 OR i.inhparent #{EQ} ch.oid OR i.inhparent #{EQ} pa.oid)
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                              WHERE t.tgconstraint #{EQ} c.oid AND t.tgenabled OPERATOR(pg_catalog.<>) 'O'
                                AND t.tgenabled OPERATOR(pg_catalog.<>) 'A')
          SQL

          # Whether a foreign key from table to references_table, both
          # [schema, name], pairs exactly pairs, each [column, referenced
          # column], and, once validated, binds every row of table, as
          # STRICT_FOREIGN_KEY says. With it validated and its columns not
          # null, each row of table has exactly one row of references_table
          # whose key = its columns.
          def strict_foreign_key?(table, references_table, pairs)
            key = [table, references_table, pairs.sort]
            @strict_foreign_keys ||= {}
            @strict_foreign_keys.fetch(key) do
              found = @connection.exec_params(STRICT_FOREIGN_KEY, [*table, *references_table]).column_values(0)
              @strict_foreign_keys[key] = found.any? { JSON.parse(it).sort == pairs.sort }
            end
          end
        end
      end
    end
  end
end
