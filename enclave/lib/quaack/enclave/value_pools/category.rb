# frozen_string_literal: true

module Quaack
  module Enclave
    module ValuePools
      # The column's type's category, such as N for a number or S for text.
      module Category
        SQL = "SELECT t.typcategory FROM pg_catalog.pg_type t WHERE t.oid OPERATOR(pg_catalog.=) $1"
        LABELS = "SELECT enumlabel FROM pg_catalog.pg_enum WHERE enumtypid OPERATOR(pg_catalog.=) $1 " \
                 "ORDER BY enumsortorder"

        def self.of(conn, col) = conn.exec_params(SQL, [col.oid]).getvalue(0, 0)

        # An enum's labels, which a near miss needs when the arena holds no
        # rows, since its type has no boundary values.
        def self.labels(conn, col) = conn.exec_params(LABELS, [col.oid]).column_values(0)
      end
    end
  end
end
