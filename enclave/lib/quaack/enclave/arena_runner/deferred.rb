# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    class ArenaRunner
      # Runs the inserts, in order, then each DeferredInsert's UPDATEs. A
      # DeferredInsert runs with RETURNING tableoid, ctid, and each UPDATE
      # is keyed to one of those rows, with the values as parameters.
      # tableoid matters for a partitioned table, whose partitions can
      # repeat a ctid. If an insert returns a different number of rows than
      # it has updates, or an UPDATE doesn't find exactly its row (a
      # trigger moved it), the load fails with insert_failed.
      module Deferred
        module_function

        # statement is the runner's; quote quotes an identifier.
        def load(inserts, statement, quote)
          targets = inserts.each_with_index.map { |insert, index| run_insert(insert, index, statement) }
          inserts.zip(targets).each_with_index do |(insert, rows), index|
            run_updates(insert, rows, index, statement, quote) if rows
          end
        end

        def inserts?(inserts) = inserts.is_a?(Array) && inserts.all? { |i| i.is_a?(String) || i.is_a?(DeferredInsert) }

        def text(insert) = insert.is_a?(DeferredInsert) ? insert.sql : insert

        def run_insert(insert, index, statement)
          if insert.is_a?(String)
            run(statement, insert, [], index)
            return
          end

          rows = run(statement, returning_sql(insert.sql), [], index).rows
          raise Error.new(:insert_failed, step: :insert, index:), cause: nil unless rows.size == insert.updates.size

          rows
        end

        def run_updates(insert, rows, index, statement, quote)
          table = relation_sql(insert.sql, quote)
          insert.updates.zip(rows).each do |set, (oid, ctid)|
            next if set.empty?

            found = run(statement, *update_sql(table, set, oid, ctid, quote), index).rows.size
            raise Error.new(:insert_failed, step: :insert, index:), cause: nil unless found == 1
          end
        end

        def run(statement, sql, params, index)
          statement.call(sql, params, step: :insert, rule: :insert_failed, index:)
        end

        def returning_sql(sql)
          tree = PgQuery.parse(sql).tree
          tree.stmts[0].stmt.insert_stmt.returning_list.replace(%w[tableoid ctid].map { |name| returning(name) })
          PgQuery.deparse(tree)
        end

        def returning(name)
          PgQuery::Node.new(res_target: PgQuery::ResTarget.new(
            val: PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(
              fields: [PgQuery::Node.new(string: PgQuery::String.new(sval: name))]
            ))
          ))
        end

        def relation_sql(sql, quote)
          relation = PgQuery.parse(sql).tree.stmts[0].stmt.insert_stmt.relation
          [relation.schemaname, relation.relname].reject(&:empty?).map { |part| quote.call(part) }.join(".")
        end

        def update_sql(table, set, oid, ctid, quote)
          columns = set.keys.each_with_index.map { |c, i| "#{quote.call(c)} = $#{i + 1}" }.join(", ")
          n = set.size
          ["UPDATE #{table} SET #{columns} WHERE tableoid = $#{n + 1} AND ctid = $#{n + 2} RETURNING 1",
           set.values + [oid, ctid]]
        end
      end
    end
  end
end
