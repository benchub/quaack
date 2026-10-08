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

        # Loads the fixture rows. A row with deferred columns loads with NULL
        # there and returns its tableoid and ctid. Once every row has loaded,
        # each such row's UPDATE sets them, in load order, even to NULL, so
        # the heap keeps the load order. An INSERT that doesn't return its
        # row (a trigger skipped it), or an UPDATE that doesn't find exactly
        # its row, fails the load with fixture_load_failed.
        def load_rows(rows, insert_sql, table_sql, statement, quote)
          load = ->(sql, params, index) { statement.call(sql, params, step: :load, rule: :fixture_load_failed, index:) }
          targets = rows.each_with_index.map { |row, index| insert_row(row, index, insert_sql, load) }
          update_rows(rows, targets, load, table_sql, quote)
        end

        # The row's tableoid and ctid, when it has deferred columns.
        def insert_row(row, index, insert_sql, load)
          sql, params = insert_sql.call(row)
          if row.deferred.empty?
            load.call(sql, params, index)
            return
          end

          returned = load.call("#{sql} RETURNING tableoid, ctid", params, index).rows
          raise Error.new(:fixture_load_failed, step: :load, index:), cause: nil unless returned.size == 1

          returned.first
        end

        def update_rows(rows, targets, load, table_sql, quote)
          rows.zip(targets).each_with_index do |(row, target), index|
            next if row.deferred.empty?

            found = load.call(*update_sql(table_sql.call(row.table), row.deferred_values, *target, quote), index).rows
            raise Error.new(:fixture_load_failed, step: :load, index:), cause: nil unless found.size == 1
          end
        end

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
          ["UPDATE #{table} SET #{columns} WHERE tableoid OPERATOR(pg_catalog.=) $#{n + 1} " \
           "AND ctid OPERATOR(pg_catalog.=) $#{n + 2} RETURNING 1",
           set.values + [oid, ctid]]
        end
      end
    end
  end
end
