# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Values for a table's free columns: ones no key class, atom (from
      # the block, given the column's slot), or cut foreign key sets, and
      # that aren't generated. A column a unique key needs to vary
      # (ArenaSchema::Constraints#varying, preferring a column no CHECK
      # constrains) gets UNIQUE, which Builder#identify turns into a value
      # per distinct row. Any other
      # column with a default is left to it, and the rest get a boundary
      # value, for a boundary group, or the type's typical value,
      # whichever the column's CHECKs allow. A nullable column whose type
      # has no such value is left NULL when the query doesn't read it (see
      # Reads) and no NULLS NOT DISTINCT key holds it.
      class FreeValues
        UNIQUE = Object.new.freeze

        def initialize(schema, topology, checks, values, reads, &constrained)
          @schema = schema
          @topology = topology
          @checks = checks
          @values = values
          @reads = reads
          @constrained = constrained
          @varying = {}
        end

        def value(table, col, mode)
          return unique_value(table, col) if varying(table).include?(col.name)
          return :omit if col.default

          plain_value(table, col, mode)
        end

        private

        # UNIQUE, or NULL for a type with no distinct value.
        def unique_value(table, col) = null?(table, col) && !@values.distinct?(col) ? nil : UNIQUE

        def plain_value(table, col, mode)
          boundaries = Scenarios.boundaries(col.type, mode).select { @values.readable?(col, it) }
          typical = @values.typical(col)
          # A type with no typical value is refused if no CHECK gives one.
          @checks.satisfying(table, col, boundaries + [typical], (@values.refusal(col, table) unless typical))
        rescue Error
          raise if typical || !null?(table, col)

          nil
        end

        def null?(table, col)
          constraints = @schema.constraints(table)
          col.nullable && !@reads.read?(col.name) &&
            constraints.nulls_not_distinct.none? { it.include?(col.name) } &&
            constraints.expressions.none? { it.nulls_not_distinct && it.columns.include?(col.name) }
        end

        def varying(table)
          @varying[table] ||= @schema.constraints(table).varying(
            @schema.columns(table).select { free?(table, it) }
          ) { [@values.rank(it), @checks.checked?(table, it) ? 1 : 0] }
        end

        def free?(table, col)
          !@topology.keyed?(table, col.name) && !%w[generated identity].include?(col.default) &&
            !@topology.cut?(table, col.name) && !@constrained.call(@topology.slot(table, col.name))
        end
      end
    end
  end
end
