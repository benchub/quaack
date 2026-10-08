# frozen_string_literal: true

module Quaack
  module Enclave
    module AssumptionCheck
      # Whether the table of pg_index i has no legacy INHERITS children. A
      # scan of the table reads their rows too, and its index doesn't cover
      # them. A partitioned table's partitions are children too, but its
      # unique index covers them. A condition on pg_index i, for UNIQUE.
      module NoLegacyChildren
        EQ = "OPERATOR(pg_catalog.=)"

        SQL = <<~SQL.chomp.freeze
          NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_inherits h JOIN pg_catalog.pg_class p ON p.oid #{EQ} h.inhparent
            WHERE h.inhparent #{EQ} i.indrelid AND p.relkind OPERATOR(pg_catalog.<>) 'p')
        SQL
      end
    end
  end
end
