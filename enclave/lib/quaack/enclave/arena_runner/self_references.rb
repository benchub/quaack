# frozen_string_literal: true

module Quaack
  module Enclave
    class ArenaRunner
      # Each fixture table's foreign keys that reference the table itself,
      # which fixture-compare's reordered loads need to keep each parent row
      # before its children (ResultComparison.self_reference_levels).
      module SelfReferences
        # One row per column pair of each such key, in key order: the
        # constraint, the referencing column, and the referenced column.
        SQL = <<~SQL
          SELECT con.oid, child.attname, parent.attname
          FROM pg_catalog.pg_constraint con
          CROSS JOIN LATERAL ROWS FROM (pg_catalog.unnest(con.conkey), pg_catalog.unnest(con.confkey))
            WITH ORDINALITY AS k(child_num, parent_num, position)
          JOIN pg_catalog.pg_attribute child ON child.attrelid OPERATOR(pg_catalog.=) con.conrelid
            AND child.attnum OPERATOR(pg_catalog.=) k.child_num
          JOIN pg_catalog.pg_attribute parent ON parent.attrelid OPERATOR(pg_catalog.=) con.confrelid
            AND parent.attnum OPERATOR(pg_catalog.=) k.parent_num
          WHERE con.contype OPERATOR(pg_catalog.=) 'f'
            AND con.conrelid OPERATOR(pg_catalog.=) $1::pg_catalog.regclass
            AND con.confrelid OPERATOR(pg_catalog.=) con.conrelid
          ORDER BY con.oid, k.position
        SQL

        module_function

        # The keys, as [columns, referenced columns] pairs, from SQL's rows.
        def keys(rows)
          rows.chunk_while { |a, b| a[0] == b[0] }.map { |key| [key.map { it[1] }, key.map { it[2] }] }
        end
      end

      # The self-referencing foreign keys of each of tables (TableNames), as
      # { table => [[columns, referenced columns], ...] }. It reads them in
      # its own transaction that rolls back, and keeps them for the
      # runner's life, since arena's schema doesn't change under it. A
      # failed read raises fixture_load_failed, at the load step.
      def self_references(tables)
        missing = tables.uniq.reject { @self_references.key?(it) }
        read_self_references(missing) unless missing.empty?
        tables.to_h { [it, @self_references.fetch(it)] }
      end

      private

      def read_self_references(tables)
        refuse_unless_idle
        without_notices do
          database(:begin_failed, :begin) { @connection.exec("BEGIN") }
          read_self_references_in_transaction(tables)
        end
      end

      def read_self_references_in_transaction(tables)
        failed = false
        read_each_self_reference(tables)
      rescue Exception # rubocop:disable Lint/RescueException -- only noted, then raised again
        failed = true
        raise
      ensure
        rollback_self_references(quietly: failed)
      end

      def read_each_self_reference(tables)
        database(:begin_failed, :begin) { @connection.exec(Pipeline::DISARM_SQL) }
        tables.each do |table|
          result = statement(SelfReferences::SQL, [table_sql(table)], step: :load, rule: :fixture_load_failed,
                                                                      index: nil)
          @self_references[table] = SelfReferences.keys(result.rows)
        end
      end

      # As finish: if the read failed, a failed rollback is dropped.
      def rollback_self_references(quietly:)
        database(:rollback_failed, :rollback) { @connection.exec("ROLLBACK") }
      rescue Error
        raise unless quietly
      end
    end
  end
end
