# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Whether a fixture row may leave a column NULL when rewrite-test has no
      # value of its type to give it: the column is nullable, the queries
      # don't read it (see Reads), neither its CHECKs nor a NOT NULL domain
      # under its type rejects NULL, and no NULLS NOT DISTINCT key holds it,
      # so the NULLs never collide.
      class Nulls
        def initialize(schema, values, checks, reads)
          @schema = schema
          @values = values
          @checks = checks
          @reads = reads
        end

        def allowed?(table, col)
          col.nullable && !@reads.read?(table, col.name) && @values.nullable_type?(col) &&
            @checks.allows?(table, col, nil) && !collide?(table, col)
        end

        private

        def collide?(table, col)
          constraints = @schema.constraints(table)
          constraints.nulls_not_distinct.any? { it.include?(col.name) } ||
            constraints.expressions.any? { it.nulls_not_distinct && it.columns.include?(col.name) }
        end
      end
    end
  end
end
